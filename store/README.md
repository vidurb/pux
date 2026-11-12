# Store listings

What goes into Google Play Console and App Store Connect, other than the builds themselves.

| File | Contents |
|------|----------|
| [`listing.md`](listing.md) | Names, descriptions, App Store subtitle, promotional text and keywords |
| [`privacy-forms.md`](privacy-forms.md) | Answers for Play's Data Safety form and the App Store privacy labels, checked against the server code and the privacy policy |
| [`../brand/store/play-feature-graphic.png`](../brand/store/play-feature-graphic.png) | Play's 1024 × 500 feature graphic, from `brand/play-feature-graphic.svg` by `scripts/render-brand.sh` |

To check the copy against the stores' limits:

```bash
python3 - store/listing.md <<'EOF'
import re, sys
for m in re.finditer(r'### ([^\n]*?)\((\d+)\)\n.*?```text\n(.*?)\n```', open(sys.argv[1]).read(), re.S):
    print(f"{len(m.group(3)):>5} / {m.group(2):>4}  {m.group(1).strip()}")
EOF
```

## Screenshots

Both stores' screenshots come from the scenes in [`mobile/lib/screenshots/scenes.dart`](../mobile/lib/screenshots/scenes.dart), in store order, with the fictional Northwind Bank as the sender. They're generated into `mobile/build/` rather than committed.

**App Store**, from the iOS simulator so they show the iOS fonts and status bar. Needs Xcode; see [`mobile/ios/README.md`](../mobile/ios/README.md#app-store-screenshots).

```bash
cd mobile
ios/scripts/app_store_screenshots.sh            # writes build/app_store_screenshots/
```

**Google Play and the README**, rendered headlessly with `flutter test`, so no emulator is needed and it runs anywhere Flutter does:

```bash
cd mobile
tool/render_screenshots.sh                      # writes build/screenshots/
cp build/screenshots/readme/*.png ../brand/screenshots/   # after changing a README scene
```

| Directory | Size | For |
|-----------|------|-----|
| `play/phone` | 1080 × 1920 | Phone screenshots |
| `play/tablet-7` | 1080 × 1920 | 7-inch tablet screenshots |
| `play/tablet-10` | 1440 × 2560 | 10-inch tablet screenshots |
| `readme` | 618 × 1098 | `brand/screenshots/app-*.png` in the root README |

They're 9:16 RGB PNGs without an alpha channel, which Play requires. They render as on Android: Roboto and the Material icons come from the Flutter SDK's cache, and since widget tests have no system fonts, symbols that Roboto lacks (the "→" in the forwarding steps) come from Arial Unicode on macOS or DejaVu Sans on Linux. Set `PUX_SYMBOL_FONT` to a font file if neither is installed. There's no status bar; the scenes leave room for one.
