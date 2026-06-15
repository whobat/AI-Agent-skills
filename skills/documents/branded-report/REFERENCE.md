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
  "logo": "assets/logo.svg",         // HTML/PDF logo; SVG/PNG/JPG
  "logo_raster": "assets/logo.png"   // optional PNG/JPG logo for DOCX
}
```

All keys are optional — missing ones fall back to the neutral default theme. Any single
color or font can be overridden without supplying the rest.

### Asset paths
Relative paths in the theme (`logo`, `logo_raster`) resolve against **the theme file's own
folder**, and backslashes are normalized — so the same theme works on Windows and POSIX.
Keep a `theme.json` and an `assets/` folder together and reference `assets/logo.png` (or
`.\assets\logo.png`). The folder can live anywhere, including inside an agent's skills
directory (a folder without a `SKILL.md` is ignored by the installer and the updater).

### Logo rules
- **HTML / PDF:** uses `logo` — SVG, PNG, or JPG all embed (base64). SVG stays crisp at any
  size; a colored/dark logo reads best on the white cover.
- **DOCX:** Word cannot embed SVG, so it uses **`logo_raster`** (PNG/JPG) when present;
  otherwise it falls back to `logo` if that is itself a PNG/JPG, and failing that shows the
  `organization` name as a text wordmark. Best practice: `logo` = crisp SVG for HTML/PDF,
  `logo_raster` = a high-resolution PNG (≥ 600 px wide) for DOCX.

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

Works with `.pptx`, `.potx`, `.thmx`, `.dotx`, **`.docx`, `.xlsx`** — anything carrying an
OOXML theme (`*/theme/themeN.xml`). This is the **most accurate** source because it reads
the brand's declared color scheme and fonts, not an approximation.

## extract_theme_visual.py — image / website / PDF

When there is no Office theme, sample the colors visually:

```bash
python extract_theme_visual.py --image brand.png   --out theme.json
python extract_theme_visual.py --url https://acme.example --out theme.json --logo-dir ./assets
python extract_theme_visual.py --pdf branded.pdf --page 1 --out theme.json
```

How each source is handled:

| Source | Colors | Fonts | Logo / Organization |
|--------|--------|-------|---------------------|
| `--image` | sampled from the pixels | default (Georgia) | — / filename |
| `--pdf` | rendered page (pypdfium2) → sampled | embedded font names (pypdf) | — / filename |
| `--url` | **header band** screenshot (headless browser) → sampled | `font-family` in the page CSS | og:image / favicon; `<title>` → organization |

**The colour heuristic** keeps only saturated, mid/dark palette entries and weights
saturation far above pixel share — so a small vivid logo wins over a mostly-white page.
`primary` is the most vivid prominent colour; `secondary` is the next distinct hue;
`accent`/`light`/`border`/`muted` are derived from `primary`; `text` is `#2B2B2B`. A
greyscale source falls back to a neutral slate palette.

**Reliability (read this):** visual extraction is an **approximation — always review the
result.**
- A **PDF or image of an already-branded document** (a report, a one-pager, a logo sheet)
  gives accurate brand colours — this is the best visual source.
- A **website** reflects what is *on screen*: the header band usually carries the brand
  chrome, but a photo-heavy site can still yield content colours rather than the brand's.
  A site's live palette may also differ from its print/PowerPoint identity. Treat the
  output as a starting point and tune `colors` (and `logo`) by hand.
- For guaranteed-correct colours, prefer the **OOXML extractor** or hand-write the theme.

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

## Verification

**BEFORE generating — confirm preconditions:**

- **Theme file present and sane.** Confirm `theme.json` exists at the path passed to `--theme`. Open it and eyeball the brand colors, fonts, and logo paths. Themes produced by visual extraction (`extract_theme_visual.py`) are approximate — check that the colors look like the brand identity before committing to a full run.
- **Logo paths resolve.** Verify that the `logo` and `logo_raster` paths in `theme.json` actually exist on disk (relative to the theme file's folder). A missing logo silently falls back to an organization-name wordmark for DOCX and produces no image on the cover for HTML/PDF.
- **Headless browser available for PDF.** If `pdf` is in `--formats`, confirm that Chrome/Edge/Chromium is discoverable (`chrome --version`, `chromium --version`, or the standard install locations). If no browser is found, PDF will be silently skipped with `"pdf": null` in the output — it is better to know this up front than to discover it after a long run.
- **Fonts installed for the renderer.** The PDF renderer embeds fonts from the build machine. If the theme names a non-standard brand font (not Georgia, Arial, Calibri, etc.), verify it is installed before running; otherwise the browser substitutes silently and the PDF will not match the intended typography.

**OUTPUT verification — after generation, inspect every requested format:**

- **Parse `outputs`, not just `status`.** A `"status": "ok"` result does not mean every format was produced. Check each key in `outputs`: a `null` value means that format was requested but not produced. The reason is on stderr — surface it rather than reporting success.
- **Confirm each path exists on disk.** Even a non-null path in `outputs` should be verified to be a real, non-empty file before reporting to the user.
- **Spot-check DOCX vs HTML for known divergences.** Open the DOCX and check: (a) the heading font is the expected family (Word silently substitutes missing fonts); (b) table row banding direction may be visually inverted compared with HTML/PDF (this is a known renderer difference); (c) any raw HTML embedded in the Markdown body is silently dropped in DOCX — confirm key content is present.
- **Confirm logo and colors rendered.** On the cover page, verify the logo image appears (not just an organization-name wordmark) and that the `primary` color band is visible. A missing or wrong-path logo is a common silent failure.
- **Fail loud.** If a requested format is missing or a required asset is absent, report the gap explicitly — do not summarize the run as successful.

## Gotchas

**`"status": "ok"` does not mean all three formats were produced.**
When PDF is skipped (no browser found), the JSON output is still
`{"status": "ok", "outputs": {"pdf": null, ...}}`. A null value in `outputs` is the only
signal that a format was requested but not produced. Always inspect each key in `outputs`
rather than checking `status` alone; the reason for the skip is printed to stderr.

**HTML is always written to disk, even when `html` is not in `--formats`.**
The script builds HTML unconditionally — it is the intermediate source for the PDF renderer.
When `html` is absent from `--formats`, the path is removed from the reported `outputs` map
but the `.html` file remains in `--output-dir`. This can leave a stale or unexpected file
alongside the PDF. If the HTML is unwanted, delete it after the run.

**DOCX font stacks are truncated to the first family name.**
`docx_render.py` calls `font_value.split(",")[0]` to extract a font name from the theme's
CSS stack (e.g. `"Calibri, sans-serif"` → `"Calibri"`). Word gets only that single name.
If the font is not installed on the reader's machine, Word substitutes silently — there is
no warning and the visual result may differ from the HTML/PDF. For maximum DOCX portability,
set `fonts.heading` and `fonts.body` to a font that ships with Microsoft Office (Calibri,
Cambria, Arial, Georgia).

**DOCX table row banding is shifted one row compared with HTML/PDF.**
The DOCX renderer shades rows where the 0-based row index `ri % 2 == 0`, which makes the
header row (`ri=0`) and every second data row receive the `light` fill. The HTML renderer
uses `tr:nth-child(even)`, which shades the opposite data rows. The alternating pattern is
visually inverted between DOCX and HTML/PDF; this is inherent in the current renderers.
There is no workaround short of hand-editing the DOCX after generation.

**Raw HTML embedded in the Markdown body appears in HTML/PDF but is silently dropped in DOCX.**
The DOCX walker dispatches only the Markdown-derived tags it knows (`p`, `h1`–`h6`, `table`,
`ul`, `ol`, `pre`, `blockquote`, `hr`). Any raw HTML that the `markdown` library passes
through — `<div>`, `<span>`, `<img>`, `<br>`, etc. — hits no handler and produces no output,
without a warning. If the same source must render faithfully in all three formats, confine
the Markdown to the constructs listed in the [Markdown support](#markdown-support) table.

**`--url` theme extraction requires the same headless browser as PDF rendering.**
`extract_theme_visual.py` screenshots the page via `chrome --headless` (or Edge/Chromium);
if no browser is found it raises `SystemExit` immediately. A machine that cannot produce
PDFs also cannot extract a theme from a URL. Use `--image` or `--pdf` as the visual source
instead, or run the OOXML extractor (`extract_theme.py`) from an Office template.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.
