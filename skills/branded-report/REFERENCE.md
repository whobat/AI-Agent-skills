# branded-report — Reference

Detailed reference for `scripts/build_report.py`, `scripts/extract_theme.py`, and the
theme format. For the agent-facing workflow see [SKILL.md](SKILL.md).

## Requirements

- **Python 3.8+** with `markdown`, `python-docx`, `beautifulsoup4` (declared in
  `skill.install.json`; the repo installer pip-installs them).
- **PDF only:** a headless **Chrome / Edge / Chromium** (or Brave). The script finds it on
  `PATH` or at the standard install locations on Windows/macOS/Linux. Without one, HTML and
  DOCX are still produced and PDF is skipped with a clear message.
- HTML and DOCX need no browser.

## Theme JSON schema

```json
{
  "organization": "Your Organization",
  "colors": {
    "primary":   "#1F3A5F",   // heading band, cover title, links
    "secondary": "#3E6B89",   // subtitle, table header row, h3
    "accent":    "#5FA8D3",   // h3 marker, code left-border
    "light":     "#EEF3F7",   // banded table rows, inline-code bg, blockquote bg
    "border":    "#C9D6E0",   // heading underlines, table borders
    "muted":     "#4A4A4A",   // bold text, cover metadata
    "text":      "#2B2B2B"    // body text
  },
  "fonts": {
    "heading": "Georgia, serif",     // CSS stack; first family also used for DOCX
    "body":    "Georgia, serif",
    "mono":    "Consolas, monospace"
  },
  "logo": "assets/logo.svg"          // relative to the theme file; SVG/PNG/JPG
}
```

All keys are optional — missing ones fall back to the neutral default theme. Any single
color or font can be overridden without supplying the rest.

### Logo rules
- **HTML / PDF:** SVG, PNG, or JPG all embed (base64). A colored/dark logo reads best on
  the white cover.
- **DOCX:** Word cannot embed SVG. If `logo` is a PNG/JPG it is placed on the cover at
  55 mm; if it is an SVG (or missing), the DOCX cover shows the `organization` name as a
  text wordmark instead.

## extract_theme.py

```bash
python extract_theme.py --template Brand.pptx --out theme.json --logo-dir ./assets
```

Reads the OOXML theme (`*/theme/themeN.xml`, preferring `theme1.xml`):

| Report role | From Office theme slot |
|-------------|------------------------|
| `primary` | `accent1` |
| `secondary` | `accent2` |
| `accent` | `accent3` (→ accent2) |
| `light` | `accent6` (→ accent5 → lt2) |
| `border` | `accent4` (→ accent5) |
| `muted` | `dk2` |
| `text` | `dk1` (forced to `#2B2B2B` if pure black/white) |
| `fonts.heading` / `.body` | major / minor font |

It copies the smallest few SVGs and rasters from the template's media into `--logo-dir`
(logos/wordmarks tend to be the smallest vectors) and sets `logo` to the first. **Review
the result** — pick the logo variant you want, and remember DOCX needs PNG/JPG. The
`organization` defaults to the template filename; edit it to taste.

Works with `.pptx`, `.potx`, `.thmx`, `.dotx`, `.docx` — anything carrying an OOXML theme.

## Markdown support

Rendered consistently in all three formats:

| Markdown | Rendering |
|----------|-----------|
| `#` H1 | White text on a `primary` band; starts a new page (PDF/print) |
| `##` H2 | `primary`, bold, `border` underline |
| `###`–`######` H3+ | `secondary`, bold |
| `**bold**` | bold, `muted` color |
| `*italic*`, `` `code` `` | italic; monospace inline code with `light` background |
| `- ` / `1. ` lists | bullet / numbered, one level of nesting |
| tables | `secondary` header row (white text), `light` banded rows |
| ```` ``` ```` fenced code | monospace block (dark in HTML/PDF, `light`-shaded in DOCX) |
| `> quote` | `light` background, italic, `muted` |
| `---` | horizontal rule in `border` |
| `[text](url)` | link in `primary` |

Keep the Markdown to these constructs for identical output across formats. Deeply nested
structures (3+ list levels, nested tables) are simplified in DOCX.

## Output contract

`--json` prints:
```json
{ "status": "ok", "outputs": { "html": "<path>", "pdf": "<path|null>", "docx": "<path|null>" } }
```
A `null` value means that format was requested but could not be produced (PDF: no browser;
DOCX: error) — the reason is printed to stderr. HTML is always generated when requested,
and is also produced internally as the source for the PDF.

## Cover page

Supplying `--title` adds a branded cover (logo/wordmark, title, subtitle, metadata lines,
footer note) and the body starts on the next page. Omit `--title` for a coverless document
that begins directly with the content.

## Notes

- **Fonts:** the PDF embeds whatever font the theme names *if it is installed on the build
  machine*; otherwise the browser substitutes a similar family. For guaranteed portability
  pick a widely available family (Georgia, Arial, Calibri) or install the brand font.
- **Page size** is A4. Change the `@page size` in `build_report.py`'s CSS for Letter.
- The script writes only the files you ask for, into `--output-dir`. It changes nothing else.
