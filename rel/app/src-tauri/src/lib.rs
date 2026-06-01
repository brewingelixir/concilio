use std::env;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{App, AppHandle, Manager, RunEvent};

/// Holds the spawned BEAM child process so we can SIGTERM it on
/// app exit. The `Drop` impl is the last line of defense — if the
/// app exits via a path Tauri's event hooks don't catch (NSApp
/// quit menu, signal, panic), Drop still fires and tears down the
/// BEAM so we never leave an orphan.
struct BeamChild(Mutex<Option<Child>>);

impl Drop for BeamChild {
    fn drop(&mut self) {
        let Ok(mut guard) = self.0.lock() else {
            return;
        };
        let Some(mut child) = guard.take() else {
            return;
        };
        terminate_child(&mut child);
    }
}

fn terminate_child(child: &mut Child) {
    #[cfg(unix)]
    unsafe {
        libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
    }
    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => thread::sleep(Duration::from_millis(50)),
            Err(_) => return,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// HTTP base URL the BEAM is serving on, plus the auth token read
/// from the data dir. Both are picked once at startup; the Tauri
/// shell injects the token as a `?token=...` query so the user
/// never has to copy-paste it from the boot log. Phoenix's auth
/// plug consumes the query, stamps a session cookie, and redirects
/// to a clean URL — so the token only appears in the very first
/// request on each menu click.
struct BeamUrl {
    base: String,
    token: Mutex<Option<String>>,
}

impl BeamUrl {
    fn url_for(&self, path: &str) -> String {
        let token = self.token.lock().ok().and_then(|g| g.clone());
        match token {
            Some(t) => format!("{}{path}?token={t}", self.base),
            None => format!("{}{path}", self.base),
        }
    }

    fn set_token(&self, new_token: String) {
        if let Ok(mut guard) = self.token.lock() {
            *guard = Some(new_token);
        }
    }
}

const TRAY_OPEN: &str = "tray_open";
const TRAY_SETTINGS: &str = "tray_settings";
const TRAY_DASHBOARD: &str = "tray_dashboard";
const TRAY_RESET_TOKEN: &str = "tray_reset_token";
const TRAY_QUIT: &str = "tray_quit";

/// Sentinel the Rust shell prints around the rotated token so the
/// rpc-eval output can be parsed deterministically (logger output
/// can interleave with stdout otherwise).
const TOKEN_SENTINEL: &str = "CONCILIO_NEW_TOKEN:";

const HEALTH_PATH: &str = "/health";
const STARTUP_TIMEOUT_SECS: u64 = 30;

/// Entry point invoked from `main.rs`.
///
/// Concilio's desktop shell follows Livebook's pattern: tray-only,
/// no embedded WebView. The Rust shell spawns the BEAM, waits for
/// `/health`, opens the local URL in the user's default browser,
/// shows a tray icon, and forwards menu clicks to `open <url>`
/// (macOS) / `xdg-open` (Linux) / `cmd /c start` (Windows). All
/// rendering happens in the user's real browser, so Phoenix /
/// LiveView never has to negotiate a Tauri WebView origin.
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // Second launch: re-open the URL in the browser instead
            // of starting a second BEAM.
            if let Some(state) = app.try_state::<BeamUrl>() {
                let _ = open_in_browser(&state.url_for("/"));
            }
        }))
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let port = pick_port();
            let url = format!("http://127.0.0.1:{port}");

            let child = spawn_beam(app, port)?;
            app.manage(BeamChild(Mutex::new(Some(child))));

            wait_for_health(port)?;
            build_tray(app)?;

            // Auth token lands in `<data-dir>/auth_token` during
            // bootstrap. The endpoint is up by the time /health
            // returns 200, but the bootstrapper Task that writes
            // the token can race that signal — give it a short
            // grace window.
            let token = read_token_with_retry(Duration::from_secs(5));
            let beam_url = BeamUrl {
                base: url.clone(),
                token: Mutex::new(token),
            };

            // Auto-open the browser on first launch, mirroring
            // Livebook's behavior. Subsequent menu interactions go
            // through `open_path`.
            let initial = beam_url.url_for("/");
            app.manage(beam_url);
            let _ = open_in_browser(&initial);

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to start Tauri app")
        .run(|app_handle, event| match event {
            RunEvent::ExitRequested { .. } | RunEvent::Exit => {
                shutdown_beam(app_handle);
            }
            _ => {}
        });
}

fn pick_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("could not pick a free port");
    let port = listener.local_addr().expect("no local addr").port();
    drop(listener);
    port
}

fn spawn_beam(app: &mut App, port: u16) -> Result<Child, Box<dyn std::error::Error>> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("resource_dir failed: {e}"))?;
    let bin = resource_dir.join("rel").join("bin").join(executable_name());

    if !bin.exists() {
        return Err(format!("BEAM release binary not found at {}", bin.display()).into());
    }

    let data_dir = default_data_dir();
    std::fs::create_dir_all(&data_dir).ok();

    let mut cmd = Command::new(&bin);
    cmd.arg("start")
        .env("PHX_SERVER", "true")
        .env("PHX_HOST", "localhost")
        .env("PHX_BIND", "loopback")
        .env("PORT", port.to_string())
        .env("CONCILIO_APP", "1")
        .env("CONCILIO_DATA_DIR", &data_dir)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    cmd.spawn()
        .map_err(|e| format!("failed to spawn BEAM at {}: {e}", bin.display()).into())
}

fn executable_name() -> &'static str {
    if cfg!(windows) {
        "app.bat"
    } else {
        "app"
    }
}

fn default_data_dir() -> PathBuf {
    if let Ok(custom) = env::var("CONCILIO_DATA_DIR") {
        return PathBuf::from(custom);
    }
    home_dir().join(".concilio")
}

fn home_dir() -> PathBuf {
    if let Ok(home) = env::var("HOME") {
        return PathBuf::from(home);
    }
    if let Ok(profile) = env::var("USERPROFILE") {
        return PathBuf::from(profile);
    }
    PathBuf::from(".")
}

fn wait_for_health(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let deadline = Instant::now() + Duration::from_secs(STARTUP_TIMEOUT_SECS);
    let addr = format!("127.0.0.1:{port}");

    loop {
        if Instant::now() > deadline {
            return Err(format!(
                "BEAM did not respond on http://{addr}{HEALTH_PATH} within {STARTUP_TIMEOUT_SECS}s"
            )
            .into());
        }
        if let Ok(stream) =
            TcpStream::connect_timeout(&addr.parse().unwrap(), Duration::from_millis(200))
        {
            drop(stream);
            if let Ok(body) = http_get_body(&addr, HEALTH_PATH) {
                if body == "ok" {
                    return Ok(());
                }
            }
        }
        thread::sleep(Duration::from_millis(150));
    }
}

fn http_get_body(addr: &str, path: &str) -> Result<String, Box<dyn std::error::Error>> {
    let mut stream = TcpStream::connect(addr)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n"
    )?;

    let mut buf = String::new();
    stream.read_to_string(&mut buf)?;

    let body_start = buf.find("\r\n\r\n").ok_or("malformed HTTP response")?;
    Ok(buf[body_start + 4..].trim().to_string())
}

fn build_tray(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    let handle = app.handle();
    let open = MenuItem::with_id(
        handle,
        TRAY_OPEN,
        "Open Concilio",
        true,
        Some("CmdOrCtrl+Shift+O"),
    )?;
    let settings = MenuItem::with_id(
        handle,
        TRAY_SETTINGS,
        "Settings",
        true,
        Some("CmdOrCtrl+,"),
    )?;
    let dashboard = MenuItem::with_id(
        handle,
        TRAY_DASHBOARD,
        "Dashboard",
        true,
        Some("CmdOrCtrl+Shift+D"),
    )?;
    let separator = PredefinedMenuItem::separator(handle)?;
    let reset_token = MenuItem::with_id(
        handle,
        TRAY_RESET_TOKEN,
        "Reset Auth Token",
        true,
        None::<&str>,
    )?;
    let separator2 = PredefinedMenuItem::separator(handle)?;
    let quit = MenuItem::with_id(
        handle,
        TRAY_QUIT,
        "Quit Concilio",
        true,
        Some("CmdOrCtrl+Q"),
    )?;
    let menu = Menu::with_items(
        handle,
        &[
            &open,
            &settings,
            &dashboard,
            &separator,
            &reset_token,
            &separator2,
            &quit,
        ],
    )?;

    let tray_icon_bytes: &[u8] = include_bytes!("../icons/tray-template.png");
    let tray_icon = decode_png_to_image(tray_icon_bytes)?;

    TrayIconBuilder::with_id("concilio-tray")
        .tooltip("Concilio")
        .menu(&menu)
        .icon(tray_icon)
        .icon_as_template(true)
        .show_menu_on_left_click(true)
        .on_menu_event(handle_tray_menu)
        .build(handle)?;

    Ok(())
}

fn decode_png_to_image(
    bytes: &[u8],
) -> Result<tauri::image::Image<'static>, Box<dyn std::error::Error>> {
    let decoder = png::Decoder::new(bytes);
    let mut reader = decoder.read_info()?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf)?;

    let rgba = match info.color_type {
        png::ColorType::Rgba => buf[..info.buffer_size()].to_vec(),
        png::ColorType::Rgb => {
            let mut out = Vec::with_capacity(info.buffer_size() / 3 * 4);
            for chunk in buf[..info.buffer_size()].chunks_exact(3) {
                out.extend_from_slice(chunk);
                out.push(0xFF);
            }
            out
        }
        png::ColorType::GrayscaleAlpha => {
            let mut out = Vec::with_capacity(info.buffer_size() * 2);
            for chunk in buf[..info.buffer_size()].chunks_exact(2) {
                let g = chunk[0];
                let a = chunk[1];
                out.extend_from_slice(&[g, g, g, a]);
            }
            out
        }
        png::ColorType::Grayscale => {
            let mut out = Vec::with_capacity(info.buffer_size() * 4);
            for &g in &buf[..info.buffer_size()] {
                out.extend_from_slice(&[g, g, g, 0xFF]);
            }
            out
        }
        png::ColorType::Indexed => {
            return Err("indexed PNGs are not supported for tray icons".into())
        }
    };

    Ok(tauri::image::Image::new_owned(rgba, info.width, info.height))
}

fn handle_tray_menu(app: &AppHandle, event: MenuEvent) {
    match event.id.as_ref() {
        TRAY_OPEN => open_path(app, "/"),
        TRAY_SETTINGS => open_path(app, "/settings"),
        TRAY_DASHBOARD => open_path(app, "/dev/dashboard"),
        TRAY_RESET_TOKEN => reset_auth_token(app),
        TRAY_QUIT => {
            shutdown_beam(app);
            app.exit(0);
        }
        _ => {}
    }
}

/// Rotates the auth token via the running BEAM, copies the new
/// token to the user's clipboard, and notifies them. Uses
/// `bin/app rpc` so we avoid the SQLite single-writer contention
/// you'd hit with `bin/app eval` (which would spawn a *second*
/// VM that opens its own Repo).
fn reset_auth_token(app: &AppHandle) {
    let Some(bin) = release_bin_path(app) else {
        return;
    };

    // The eval string runs inside the live BEAM, so the SQLite
    // Repo is the same one already serving requests.
    let eval = format!(
        "IO.puts(\"{TOKEN_SENTINEL}\" <> Concilio.Release.reset_token())"
    );

    let output = match Command::new(&bin)
        .arg("rpc")
        .arg(&eval)
        .stdin(Stdio::null())
        .output()
    {
        Ok(o) => o,
        Err(_) => return,
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let new_token = stdout
        .lines()
        .find_map(|line| line.strip_prefix(TOKEN_SENTINEL))
        .map(|s| s.trim().to_string());

    let Some(new_token) = new_token else {
        notify("Token reset failed", "See logs for details.");
        return;
    };

    if let Some(state) = app.try_state::<BeamUrl>() {
        state.set_token(new_token.clone());
    }

    let _ = copy_to_clipboard(&new_token);
    notify("Auth token reset", "New token copied to clipboard.");
}

fn release_bin_path(app: &AppHandle) -> Option<PathBuf> {
    let resource_dir = app.path().resource_dir().ok()?;
    Some(resource_dir.join("rel").join("bin").join(executable_name()))
}

fn copy_to_clipboard(text: &str) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        let mut child = Command::new("pbcopy").stdin(Stdio::piped()).spawn()?;
        if let Some(stdin) = child.stdin.as_mut() {
            stdin.write_all(text.as_bytes())?;
        }
        child.wait()?;
    }
    #[cfg(target_os = "linux")]
    {
        // Try wl-copy first (Wayland), fall back to xclip (X11).
        let attempted = Command::new("wl-copy")
            .stdin(Stdio::piped())
            .spawn()
            .or_else(|_| {
                Command::new("xclip")
                    .args(["-selection", "clipboard"])
                    .stdin(Stdio::piped())
                    .spawn()
            });
        if let Ok(mut child) = attempted {
            if let Some(stdin) = child.stdin.as_mut() {
                stdin.write_all(text.as_bytes())?;
            }
            child.wait()?;
        }
    }
    #[cfg(target_os = "windows")]
    {
        let mut child = Command::new("cmd")
            .args(["/C", "clip"])
            .stdin(Stdio::piped())
            .spawn()?;
        if let Some(stdin) = child.stdin.as_mut() {
            stdin.write_all(text.as_bytes())?;
        }
        child.wait()?;
    }
    Ok(())
}

fn notify(title: &str, body: &str) {
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "display notification \"{}\" with title \"{}\"",
            escape_apple_script(body),
            escape_apple_script(title)
        );
        let _ = Command::new("osascript").args(["-e", &script]).status();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("notify-send").arg(title).arg(body).status();
    }
    #[cfg(target_os = "windows")]
    {
        // PowerShell toast notification — best-effort.
        let ps = format!(
            "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; \
             $template = '<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>'; \
             $xml = New-Object Windows.Data.Xml.Dom.XmlDocument; \
             $xml.LoadXml($template); \
             $toast = New-Object Windows.UI.Notifications.ToastNotification($xml); \
             [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Concilio').Show($toast)",
            title, body
        );
        let _ = Command::new("powershell").args(["-Command", &ps]).status();
    }
}

#[cfg(target_os = "macos")]
fn escape_apple_script(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn open_path(app: &AppHandle, path: &str) {
    let Some(state) = app.try_state::<BeamUrl>() else {
        return;
    };
    let _ = open_in_browser(&state.url_for(path));
}

fn read_token_with_retry(timeout: Duration) -> Option<String> {
    let path = default_data_dir().join("auth_token");
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(content) = std::fs::read_to_string(&path) {
            let trimmed = content.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
        if Instant::now() > deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(150));
    }
}

fn open_in_browser(url: &str) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        Command::new("open").arg(url).spawn()?.wait()?;
    }
    #[cfg(target_os = "linux")]
    {
        Command::new("xdg-open").arg(url).spawn()?.wait()?;
    }
    #[cfg(target_os = "windows")]
    {
        Command::new("cmd").args(["/C", "start", "", url]).spawn()?.wait()?;
    }
    Ok(())
}

fn shutdown_beam(app: &AppHandle) {
    let Some(state) = app.try_state::<BeamChild>() else {
        return;
    };
    let Ok(mut guard) = state.0.lock() else {
        return;
    };
    let Some(mut child) = guard.take() else {
        return;
    };
    terminate_child(&mut child);
}
