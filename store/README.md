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

Capture current native app screens on target devices or simulators before submitting store listings. Verify current store size and format requirements before uploading.
