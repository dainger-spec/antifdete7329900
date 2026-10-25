# Branding

Drop your own files here; `scripts/build-app.sh` bundles them:

- `logo.png` — square PNG (1024×1024 is plenty). Shown on the welcome screen
  and on the splash that covers the VM while it boots, instead of the drawn
  default mark (`Brand.swift`).
- `AppIcon.icns` — the Dock/Finder icon. Make one from a 1024×1024 PNG:

  ```bash
  mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s logo.png --out AppIcon.iconset/icon_${s}x${s}.png
    sips -z $((s*2)) $((s*2)) logo.png --out AppIcon.iconset/icon_${s}x${s}@2x.png
  done
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  ```

The app's name is `Brand.name` in `Sources/VMLauncher/Brand.swift` and
`CFBundleDisplayName` in `Resources/Info.plist`.
