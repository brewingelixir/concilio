# Icons

Tauri expects these files at build time:

- `32x32.png` (Linux)
- `128x128.png` (Linux)
- `128x128@2x.png` (Linux retina)
- `AppIcon.icns` (macOS)
- `icon.ico` (Windows)
- `tray-template.png` (22×22 monochrome with alpha; macOS template image)
- `tray-template@2x.png` (44×44)

## Regenerating

Concilio's logo is the inline SVG component in
`lib/concilio_web/components/layouts.ex` (`<.logo>`). To turn it
into all the bundle icons + tray template:

1. Render the SVG to a 1024×1024 PNG with a transparent
   background. macOS:

       sips -z 1024 1024 -s format png logo.svg --out logo.png

   Or render via headless Chrome / `rsvg-convert` / `inkscape`.

2. Use `tauri-cli` to generate the bundle icons:

       cargo install tauri-cli --version "^2.0"
       cargo tauri icon /path/to/logo.png \
         --output rel/app/src-tauri/icons

3. For the tray template (macOS auto-tints to match menu bar),
   render the same SVG at 22×22 + 44×44 with **black fill on
   transparent background** and save as `tray-template.png` /
   `tray-template@2x.png` in this directory.

The regenerated PNGs / .icns / .ico can be committed (small,
binary, but stable across builds).
