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
| `play-feature-graphic.svg` | Google Play feature graphic, 1024 × 500. Rendered to `store/play-feature-graphic.png` |
| `app/*.svg` | Sources for the platform icons and splash screen |

The logo files are drawn as paths, so they need no font. `og-image.svg` and `play-feature-graphic.svg` set their text in Helvetica Neue, so render them where it is installed, such as macOS. Leave clear space of at least the p's stem width around the logo.

The feature graphic keeps everything at least 64px in from its edges, because Play crops and overlays it in some places, and has a solid background: Play rejects one with transparency, so `render-brand.sh` flattens it.

`screenshots/` holds the README's images: `site-*` are of the website, (see [`store/README.md`](../store/README.md#screenshots) for store captures).

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
```

Native platform icon assets are maintained in their respective platform directories.
