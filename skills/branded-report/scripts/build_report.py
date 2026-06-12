#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build a branded report from Markdown into HTML, PDF, and/or DOCX with one consistent theme.

  python build_report.py --input report.md --theme theme.json \
      --formats html,pdf,docx --output-dir out --title "..." --subtitle "..."

The theme (colors, fonts, logo, organization) comes from a JSON file — generate it from a
PowerPoint/Office template with extract_theme.py, or hand-write one (see theme.example.json).
HTML always works (stdlib + `markdown`). PDF needs a headless Chrome/Edge/Chromium on PATH.
DOCX needs `python-docx` + `beautifulsoup4`.

The script is deterministic and never calls an LLM.
"""
import argparse
import base64
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import markdown  # required

DEFAULT_THEME = {
    "organization": "Your Organization",
    "colors": {
        "primary": "#1F3A5F",   # headings band / title / links
        "secondary": "#3E6B89",  # subtitle / table header / h3
        "accent": "#5FA8D3",     # h3 marker / code accent
        "light": "#EEF3F7",      # banded rows / inline-code bg / blockquote bg
        "border": "#C9D6E0",     # h2 underline / table borders
        "muted": "#4A4A4A",      # strong / meta text
        "text": "#2B2B2B",       # body text
    },
    "fonts": {"heading": "Georgia, serif", "body": "Georgia, serif", "mono": "Consolas, monospace"},
    "logo": None,
}


def load_theme(path):
    theme = json.loads(json.dumps(DEFAULT_THEME))  # deep copy
    if path:
        user = json.loads(Path(path).read_text(encoding="utf-8"))
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(theme.get(k), dict):
                theme[k].update(v)
            else:
                theme[k] = v
    return theme


def resolve_logo(theme, theme_path):
    """Return (data_uri_or_None, raster_path_or_None) for HTML and DOCX respectively."""
    logo = theme.get("logo")
    if not logo:
        return None, None
    p = Path(logo)
    if not p.is_absolute() and theme_path:
        p = (Path(theme_path).parent / logo).resolve()
    if not p.exists():
        print(f"  ! logo not found: {p}", file=sys.stderr)
        return None, None
    ext = p.suffix.lower()
    mime = {".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg"}.get(ext, "application/octet-stream")
    data_uri = f"data:{mime};base64," + base64.b64encode(p.read_bytes()).decode("ascii")
    raster = str(p) if ext in (".png", ".jpg", ".jpeg") else None
    return data_uri, raster


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------
def build_css(c, f):
    return f"""
@page {{ size: A4; margin: 22mm 18mm 20mm 18mm; }}
* {{ box-sizing: border-box; }}
html {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
body {{ font-family: {f['body']}; font-size: 10.5pt; line-height: 1.5; color: {c['text']}; margin: 0; }}
.cover {{ height: 247mm; display: flex; flex-direction: column; page-break-after: always; }}
.cover .logo {{ width: 58mm; margin-bottom: auto; }}
.cover .wordmark {{ font-family: {f['heading']}; font-size: 22pt; font-weight: bold;
  color: {c['secondary']}; margin-bottom: auto; }}
.cover .band {{ border-top: 3px solid {c['primary']}; border-bottom: 3px solid {c['primary']};
  padding: 10mm 0 9mm 0; margin-bottom: 14mm; }}
.cover h1 {{ font-family: {f['heading']}; font-size: 30pt; color: {c['primary']};
  margin: 0 0 4mm 0; line-height: 1.1; border: none; background: none; padding: 0; }}
.cover .subtitle {{ font-size: 15pt; color: {c['secondary']}; font-style: italic; }}
.cover .meta {{ margin-top: 8mm; font-size: 10.5pt; color: {c['muted']}; }}
.cover .meta b {{ color: {c['secondary']}; }}
.cover .footer-note {{ margin-top: auto; font-size: 9pt; color: #888;
  border-top: 1px solid {c['border']}; padding-top: 4mm; }}
h1 {{ font-family: {f['heading']}; font-size: 19pt; color: #fff; background: {c['primary']};
  padding: 5mm 6mm; margin: 0 0 6mm 0; line-height: 1.2;
  page-break-before: always; page-break-after: avoid; border-radius: 2px; }}
h1:first-of-type {{ page-break-before: avoid; }}
h2 {{ font-family: {f['heading']}; font-size: 14.5pt; color: {c['primary']}; margin: 8mm 0 2.5mm 0;
  padding-bottom: 1.5mm; border-bottom: 2px solid {c['border']}; page-break-after: avoid; }}
h3 {{ font-family: {f['heading']}; font-size: 11.5pt; color: {c['secondary']};
  margin: 5mm 0 1.5mm 0; page-break-after: avoid; }}
h3::before {{ content: "\\258E"; color: {c['accent']}; margin-right: 2mm; }}
p {{ margin: 0 0 2.5mm 0; }}
strong {{ color: {c['muted']}; }}
a {{ color: {c['primary']}; text-decoration: none; }}
table {{ width: 100%; border-collapse: collapse; margin: 3mm 0 5mm 0; font-size: 9pt; page-break-inside: avoid; }}
th {{ background: {c['secondary']}; color: #fff; text-align: left; padding: 2mm 2.5mm; font-weight: bold; border: 1px solid {c['secondary']}; }}
td {{ padding: 1.8mm 2.5mm; border: 1px solid {c['border']}; vertical-align: top; }}
tr:nth-child(even) td {{ background: {c['light']}; }}
pre {{ background: #2f2a25; color: #f3ece2; padding: 3.5mm 4mm; border-left: 3px solid {c['accent']};
  border-radius: 2px; font-family: {f['mono']}; font-size: 8.3pt; line-height: 1.4;
  white-space: pre-wrap; word-break: break-word; page-break-inside: avoid; margin: 2mm 0 4mm 0; }}
code {{ font-family: {f['mono']}; font-size: 9pt; background: {c['light']}; color: {c['muted']};
  padding: 0.3mm 1.2mm; border-radius: 2px; }}
pre code {{ background: none; color: inherit; padding: 0; font-size: 8.3pt; }}
blockquote {{ border-left: 4px solid {c['border']}; background: {c['light']}; margin: 3mm 0;
  padding: 2.5mm 4mm; color: {c['muted']}; font-style: italic; }}
ul, ol {{ margin: 0 0 3mm 0; padding-left: 6mm; }}
li {{ margin-bottom: 1mm; }}
hr {{ border: none; border-top: 1px solid {c['border']}; margin: 6mm 0; }}
"""


def md_to_html_body(md_text):
    m = markdown.Markdown(extensions=["tables", "fenced_code", "sane_lists"])
    return m.convert(md_text)


def build_html(md_text, theme, theme_path, title, subtitle, meta_lines, footer_note):
    c, f = theme["colors"], theme["fonts"]
    logo_uri, _ = resolve_logo(theme, theme_path)
    body = md_to_html_body(md_text)
    org = theme.get("organization", "")
    # Logo if available; otherwise the organization name as a text wordmark (kept consistent
    # with the DOCX cover, which always shows the organization).
    if logo_uri:
        brand_html = f'<img class="logo" src="{logo_uri}" alt="{org}"/>'
    elif org:
        brand_html = f'<div class="wordmark">{org}</div>'
    else:
        brand_html = ""
    meta_html = "".join(f"<p>{line}</p>" for line in meta_lines)
    cover = ""
    if title:
        cover = f"""<section class="cover">
  {brand_html}
  <div class="band"><h1>{title}</h1>{f'<div class="subtitle">{subtitle}</div>' if subtitle else ''}</div>
  <div class="meta">{meta_html}</div>
  {f'<div class="footer-note">{footer_note}</div>' if footer_note else ''}
</section>"""
    return f"""<!DOCTYPE html>
<html lang="da"><head><meta charset="utf-8"><title>{title or theme.get('organization','Report')}</title>
<style>{build_css(c, f)}</style></head>
<body>
{cover}
{body}
</body></html>"""


# ---------------------------------------------------------------------------
# PDF (headless browser)
# ---------------------------------------------------------------------------
def find_browser():
    names = ["chrome", "google-chrome", "chromium", "chromium-browser", "msedge", "brave"]
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
    ]
    for p in candidates:
        if Path(p).exists():
            return p
    return None


def build_pdf(html_path, pdf_path):
    browser = find_browser()
    if not browser:
        print("  ! No headless browser (Chrome/Edge/Chromium) found — skipping PDF.\n"
              "    Install one, or open the HTML and Print to PDF.", file=sys.stderr)
        return False
    uri = Path(html_path).resolve().as_uri()
    with tempfile.TemporaryDirectory() as prof:
        cmd = [browser, "--headless", "--disable-gpu", f"--user-data-dir={prof}",
               "--no-pdf-header-footer", f"--print-to-pdf={pdf_path}", uri]
        r = subprocess.run(cmd, capture_output=True, text=True)
    if Path(pdf_path).exists() and Path(pdf_path).stat().st_size > 0:
        return True
    print(f"  ! PDF render failed (browser exit {r.returncode}). {r.stderr[:300]}", file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# DOCX (python-docx)
# ---------------------------------------------------------------------------
def build_docx(md_text, theme, theme_path, title, subtitle, meta_lines, docx_path):
    try:
        from docx_render import render_docx  # local module next to this script
    except ImportError:
        from .docx_render import render_docx  # pragma: no cover
    render_docx(md_text, theme, theme_path, title, subtitle, meta_lines, docx_path)
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="Build a branded report (HTML/PDF/DOCX) from Markdown.")
    ap.add_argument("--input", required=True, help="Markdown source file")
    ap.add_argument("--theme", help="Theme JSON (omit for the neutral default)")
    ap.add_argument("--formats", default="html,pdf,docx", help="Comma list: html,pdf,docx")
    ap.add_argument("--output-dir", default=".", help="Where to write outputs")
    ap.add_argument("--name", help="Base output filename (default: input stem)")
    ap.add_argument("--title", help="Cover title (omit to skip the cover page)")
    ap.add_argument("--subtitle", default="", help="Cover subtitle")
    ap.add_argument("--meta", action="append", default=[],
                    help="Cover meta line (repeatable). Use **bold:** markdown for labels.")
    ap.add_argument("--footer-note", default="", help="Small note at the bottom of the cover")
    ap.add_argument("--json", action="store_true", help="Print a JSON result summary")
    args = ap.parse_args(argv)

    md_text = Path(args.input).read_text(encoding="utf-8")
    theme = load_theme(args.theme)
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = args.name or Path(args.input).stem
    formats = [x.strip().lower() for x in args.formats.split(",") if x.strip()]

    # Cover meta as inline-markdown -> simple HTML for the cover.
    def md_inline(s):
        return (s.replace("**", "\x00").replace("\x00", "<b>", 1).replace("\x00", "</b>", 1)
                if "**" in s else s)
    meta_lines = [md_inline(m) for m in args.meta]

    results = {}
    html = build_html(md_text, theme, args.theme, args.title, args.subtitle, meta_lines, args.footer_note)
    html_path = out_dir / f"{stem}.html"
    html_path.write_text(html, encoding="utf-8")
    results["html"] = str(html_path)  # HTML is always produced (needed for PDF too)

    if "pdf" in formats:
        pdf_path = out_dir / f"{stem}.pdf"
        results["pdf"] = str(pdf_path) if build_pdf(html_path, str(pdf_path)) else None

    if "docx" in formats:
        docx_path = out_dir / f"{stem}.docx"
        try:
            build_docx(md_text, theme, args.theme, args.title, args.subtitle, meta_lines, str(docx_path))
            results["docx"] = str(docx_path)
        except Exception as e:  # noqa: BLE001
            print(f"  ! DOCX failed: {e}", file=sys.stderr)
            results["docx"] = None

    if "html" not in formats:
        # HTML was only an intermediate for PDF; drop it from the reported outputs.
        results.pop("html", None)

    if args.json:
        print(json.dumps({"status": "ok", "outputs": results}, ensure_ascii=False, indent=2))
    else:
        for fmt, path in results.items():
            print(f"  {fmt:5} -> {path}" if path else f"  {fmt:5} -> (skipped)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
