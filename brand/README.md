# pux brand

## Name

Always **pux**, in lowercase, including at the start of a sentence and in app display names.

## Logo

The mark is the letter p with a keyhole for a counter. The wordmark uses the same p, so don't place the mark beside the wordmark: it reads "p pux".

| File | Use |
|------|-----|
| `pux-icon.svg` | The mark on its pine tile: favicons, avatars |
| `pux-mark.svg` | The mark alone, in pine |
| `pux-wordmark.svg` | Wordmark on light backgrounds |
| `pux-wordmark-dark.svg` | Wordmark on dark backgrounds |
| `og-image.svg` | Social share card |
| `app/*.svg` | Sources for the platform icons and splash screen |

All of these are drawn as paths, so they need no font. Leave clear space of at least the p's stem width around the logo.

Below 24px the keyhole stops being readable. The icon still works as a p, but check any new use at its real size.

## Colour

| Name | Hex | Use |
|------|-----|-----|
| Pine | `#0E3B32` | Primary brand colour, icon background |
| Mint | `#DDF3D6` | The mark on pine, text on pine |
| Ink | `#0C1F1B` | Text on light backgrounds |
| Paper | `#F5F8F1` | Page background, light mode |
| Night | `#0A1714` | Page background, dark mode |
| Leaf | `#17654F` | Links on light backgrounds |
| Amber | `#8A4B00` | Cautions. Use with `#FDF0D8` behind it |

Dark mode variants are in `server/priv/static/assets/app.css`.

## Type

System fonts only, so the site loads nothing from a third party.

- **Headings:** Helvetica Neue and its system equivalents, weight 800, slightly tight tracking.
- **Body:** `system-ui`.
- **Codes and technical values:** `ui-monospace`.

## Regenerating assets

```bash
./scripts/render-brand.sh                 # needs rsvg-convert
cd mobile
flutter pub run flutter_launcher_icons
flutter pub run flutter_native_splash:create
```

Then revert what the generators change beyond the images, because these break or bloat the iOS build:

- `ios/Runner.xcodeproj/project.pbxproj`: `flutter_launcher_icons` sets a wrong asset-symbol setting.
- `ios/Runner/Info.plist`: `flutter_native_splash` reformats the file and hides the status bar.
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json`, along with the legacy 50, 57 and 72 point PNGs it adds. Restore the macOS `Contents.json` too.
