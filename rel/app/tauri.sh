#!/usr/bin/env bash
# Concilio Tauri orchestration script.
#
# Usage: ./rel/app/tauri.sh [command] [options]
#
# Commands:
#   dev              cargo tauri dev (live-reload Rust shell against running mix server)
#   build [args]     mix release app + cargo tauri build [args]
#   app  [args]      build + install + open app (macOS / Windows)
#   <other>          forwarded to `cargo tauri`
#
# Honors CONCILIO_APP=1 throughout so router + config branches enable
# app-mode behavior (LiveDashboard route exposed, etc.).
set -euo pipefail

main() {
  export CONCILIO_APP="1"

  root_dir="$(cd "$(dirname "$0")" && pwd)"
  mix_project_dir="${root_dir}/../.."
  app="Concilio"

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    Darwin*)              os=darwin  ;;
    Linux*)               os=linux   ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
  esac

  profile="release"
  for arg in "$@"; do
    if [ "$arg" = "--debug" ]; then
      profile="debug"
      break
    fi
  done

  release_root="$root_dir/src-tauri/rel-${os}"

  # Tauri picks up the per-OS bundled release from a known path
  # under src-tauri/. We override `bundle.resources` at invocation
  # time so a single tauri.conf.json works across all targets.
  config="--config"
  config_json="{\"bundle\":{\"resources\":{\"rel-${os}\":\"rel\"}}}"

  if [ -z "${MIX_ENV:-}" ] && [ "$profile" = "release" ] && [ "${1:-}" != "dev" ]; then
    export MIX_ENV="prod"
  fi

  command="${1:-}"

  case "$command" in
    dev)
      cargo tauri "$@"
      ;;
    app)
      shift
      mix_release
      bundles_flag=""
      if [ "$os" = "darwin" ]; then
        bundles_flag="--bundles app"
      fi
      cargo tauri build "$config" "$config_json" $bundles_flag "$@"
      open_app "$@"
      ;;
    build)
      shift
      mix_release
      # macOS DMG bundling needs AppleScript "control Finder"
      # permission (granted interactively, once, on first
      # successful run). On a freshly-installed dev box the prompt
      # never appears non-interactively and `bundle_dmg.sh` exits
      # with an osascript -1743 error. CI runners come up fresh
      # each time and don't hit this. So the local default is
      # `--bundles app`; CI sets `CONCILIO_BUNDLE_ALL=1` to opt in
      # to the full bundle (dmg / nsis / appimage / deb).
      bundles_flag=""
      if [ "$os" = "darwin" ] && [ "${CONCILIO_BUNDLE_ALL:-0}" != "1" ]; then
        bundles_flag="--bundles app"
      fi
      cargo tauri build "$config" "$config_json" $bundles_flag "$@"
      ;;
    *)
      cargo tauri "$@"
      ;;
  esac
}

mix_release() {
  (
    cd "${mix_project_dir}"
    # Prod release: fetch only prod deps, build assets (digest + gz),
    # then assemble. We deliberately avoid `mix setup` because that
    # alias runs `ecto.setup` (and therefore `mix run priv/repo/seeds.exs`)
    # which boots the app at MIX_ENV=prod, hits the runtime.exs
    # `server: true` default, and crashes if port 4000 is taken.
    mix deps.get --only prod
    mix compile
    mix assets.deploy
    mix release app --overwrite --path "$release_root"
  )
}

open_app() {
  case "$os" in
    darwin)
      trap 'osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1' INT TERM
      lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
      "$lsregister" -u "/Applications/${app}.app" || true
      app_path="${root_dir}/src-tauri/target/${profile}/bundle/macos/${app}.app"
      open -W --stdout "$(tty)" --stderr "$(tty)" "$app_path" --args "$@"
      ;;
    windows)
      echo "Installing $app..."
      "${CARGO_TARGET_DIR:-${root_dir}/src-tauri/target}/${profile}/bundle/nsis/${app}"*setup.exe //S
      echo "Running $app..."
      "$LOCALAPPDATA/${app}/${app}.exe" "$@"
      ;;
    linux)
      echo "AppImage at: ${root_dir}/src-tauri/target/${profile}/bundle/appimage/${app}_*.AppImage"
      ;;
  esac
}

main "$@"
