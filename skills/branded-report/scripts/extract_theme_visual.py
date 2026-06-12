#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Extract a branded-report theme from a VISUAL source — an image, a website, or a PDF —
when there is no Office theme to read (use extract_theme.py for .pptx/.docx/.xlsx, which
have a real colour scheme).

  python extract_theme_visual.py --image brand.png   --out theme.json
  python extract_theme_visual.py --url https://acme.example --out theme.json --logo-dir ./assets
  python extract_theme_visual.py --pdf report.pdf --page 1 --out theme.json

How it works (HEURISTIC — always review the result):
  - the source is rendered to an image (URL via headless Chrome/Edge; PDF via pypdfium2),
  - the dominant colours are sampled and mapped to report roles by saturation/lightness,
  - for a URL the page title -> organization, font-family declarations -> fonts, and
    og:image / favicon / first header image -> logo,
  - for a PDF the embedded font names -> fonts (best-effort).

Unlike the OOXML extractor this is an approximation: it guesses brand colours from pixels.
Open the theme.json and tune `colors` / `fonts` / `logo` afterwards.

Deps: Pillow (always), pypdfium2 (PDF), a headless browser (URL). stdlib for HTML/fetch.
"""
import argparse
import colorsys
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image

TEXT_DEFAULT = "#2B2B2B"


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
def _hex(rgb):
    return "#%02X%02X%02X" % (int(rgb[0]), int(rgb[1]), int(rgb[2]))


def _hls(rgb):
    r, g, b = [x / 255.0 for x in rgb[:3]]
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h, l, s


def _from_hls(h, l, s):
    r, g, b = colorsys.hls_to_rgb(h, max(0.0, min(1.0, l)), max(0.0, min(1.0, s)))
    return (round(r * 255), round(g * 255), round(b * 255))


def sample_palette(image, n=16):
    """Return [(rgb, share)] for the dominant colours, most prominent first."""
    img = image.convert("RGB")
    img.thumbnail((400, 400))
    q = img.quantize(colors=n, method=Image.Quantize.FASTOCTREE)
    pal = q.getpalette()
    counts = q.getcolors() or []  # [(count, index)]
    total = sum(c for c, _ in counts) or 1
    out = []
    for count, idx in counts:
        rgb = (pal[idx * 3], pal[idx * 3 + 1], pal[idx * 3 + 2])
        out.append((rgb, count / total))
    out.sort(key=lambda x: x[1], reverse=True)
    return out


def map_colors(palette):
    """Map a sampled palette to the report's colour roles (heuristic)."""
    # Saturated, mid-lightness colours are brand-candidate material. Brand colours are
    # VIVID rather than frequent (a logo/accent is a small slice of a mostly-white page),
    # so weight saturation far above pixel share, and penalise very light/pale colours.
    cands = []
    for rgb, share in palette:
        h, l, s = _hls(rgb)
        if s > 0.25 and 0.12 < l < 0.72 and share > 0.002:
            light_pen = 1.0 - max(0.0, l - 0.5)          # favour mid/dark over pale
            score = share * (s ** 3) * light_pen
            cands.append((rgb, share, h, l, s, score))
    cands.sort(key=lambda c: c[5], reverse=True)

    colors = {}
    if cands:
        primary = cands[0]
        colors["primary"] = _hex(primary[0])
        ph = primary[2]
        # secondary: most prominent candidate with a clearly different hue.
        secondary = next((c for c in cands[1:] if abs((c[2] - ph + 0.5) % 1.0 - 0.5) > 0.08), None)
        colors["secondary"] = _hex(secondary[0]) if secondary else _hex(_from_hls(ph, primary[3] * 0.7, primary[4]))
        # accent: a brighter sibling of primary.
        colors["accent"] = _hex(_from_hls(ph, min(0.72, primary[3] + 0.22), max(0.35, primary[4] * 0.9)))
        # light: very light tint of primary.
        colors["light"] = _hex(_from_hls(ph, 0.94, 0.30))
        # border: light-mid tint.
        colors["border"] = _hex(_from_hls(ph, 0.80, 0.25))
        # muted: dark, slightly desaturated primary.
        colors["muted"] = _hex(_from_hls(ph, 0.32, 0.35))
    else:
        # Greyscale / no clear brand colour — fall back to a neutral slate.
        colors = {"primary": "#1F3A5F", "secondary": "#3E6B89", "accent": "#5FA8D3",
                  "light": "#EEF3F7", "border": "#C9D6E0", "muted": "#4A4A4A"}
    colors["text"] = TEXT_DEFAULT
    return colors


# ---------------------------------------------------------------------------
# Source renderers
# ---------------------------------------------------------------------------
def render_pdf_page(pdf_path, page_index, scale=2.0):
    import pypdfium2 as pdfium
    pdf = pdfium.PdfDocument(str(pdf_path))
    page = pdf[page_index]
    pil = page.render(scale=scale).to_pil()
    return pil


def screenshot_url(url, out_png):
    import shutil
    import subprocess
    import tempfile
    browser = None
    for n in ("chrome", "google-chrome", "chromium", "chromium-browser", "msedge"):
        browser = shutil.which(n) or browser
    if not browser:
        for p in (r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                  r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                  "/usr/bin/google-chrome", "/usr/bin/chromium"):
            if Path(p).exists():
                browser = p
                break
    if not browser:
        raise SystemExit("No headless browser found — needed to render a URL.")
    with tempfile.TemporaryDirectory() as prof:
        subprocess.run([browser, "--headless", "--disable-gpu", f"--user-data-dir={prof}",
                        "--hide-scrollbars", "--window-size=1280,1600",
                        f"--screenshot={out_png}", url],
                       capture_output=True, text=True, timeout=90)
    if not Path(out_png).exists():
        raise SystemExit(f"Failed to screenshot {url}")


# ---------------------------------------------------------------------------
# URL metadata (org / fonts / logo)
# ---------------------------------------------------------------------------
def fetch(url, binary=False, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 branded-report"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (user-provided URL)
        data = r.read()
    return data if binary else data.decode("utf-8", "replace")


def url_metadata(url, html, logo_dir):
    meta = {}
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    if m:
        title = re.sub(r"\s+", " ", m.group(1)).strip()
        parts = [p.strip() for p in re.split(r"[|–—-]", title) if p.strip()]
        generic = {"forside", "home", "front page", "welcome", "velkommen", "index",
                   "startside", "homepage", "start"}
        named = [p for p in parts if p.lower() not in generic]
        meta["organization"] = (named[-1] if named else (parts[-1] if parts else title))[:60]
    fams = re.findall(r"font-family\s*:\s*([^;}{\"']+)", html, re.I)
    fams = [f.strip() for f in fams if "inherit" not in f.lower()]
    if fams:
        meta["fonts"] = {"heading": fams[0].strip(), "body": (fams[1] if len(fams) > 1 else fams[0]).strip(),
                         "mono": "Consolas, monospace"}
    # logo: og:image -> apple-touch/icon -> first header img
    logo_url = None
    m = re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)', html, re.I)
    if m:
        logo_url = m.group(1)
    if not logo_url:
        m = re.search(r'<link[^>]+rel=["\'][^"\']*icon[^"\']*["\'][^>]+href=["\']([^"\']+)', html, re.I)
        if m:
            logo_url = m.group(1)
    if logo_url and logo_dir:
        logo_url = urllib.parse.urljoin(url, logo_url)
        try:
            data = fetch(logo_url, binary=True)
            ext = Path(urllib.parse.urlparse(logo_url).path).suffix.lower() or ".png"
            if ext in (".png", ".jpg", ".jpeg", ".svg", ".ico"):
                logo_dir = Path(logo_dir)
                logo_dir.mkdir(parents=True, exist_ok=True)
                dest = logo_dir / ("logo" + (".png" if ext == ".ico" else ext))
                dest.write_bytes(data)
                meta["logo"] = str(dest)
        except Exception as e:  # noqa: BLE001
            print(f"  ! could not fetch logo {logo_url}: {e}", file=sys.stderr)
    return meta


def pdf_fonts(pdf_path):
    try:
        from pypdf import PdfReader
    except ImportError:
        return None
    try:
        reader = PdfReader(str(pdf_path))
        names = set()
        for page in reader.pages[:3]:
            res = page.get("/Resources")
            fonts = res.get("/Font") if res else None
            if not fonts:
                continue
            for f in fonts.values():
                bf = f.get_object().get("/BaseFont")
                if bf:
                    names.add(re.sub(r"^[A-Z]{6}\+", "", str(bf).lstrip("/")))
        names = sorted(names)
        if names:
            head = names[0].split("-")[0].split(",")[0]
            return {"heading": f"{head}, serif", "body": f"{head}, serif", "mono": "Consolas, monospace"}
    except Exception:  # noqa: BLE001
        return None
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def build_theme(colors, organization, fonts=None, logo=None):
    return {
        "organization": organization or "Your Organization",
        "colors": colors,
        "fonts": fonts or {"heading": "Georgia, serif", "body": "Georgia, serif", "mono": "Consolas, monospace"},
        "logo": logo,
        "logo_raster": None,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Extract a branded-report theme from an image, URL, or PDF (heuristic).")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--image", help="Image file (PNG/JPG) to sample colours from")
    src.add_argument("--url", help="Website URL to render and sample")
    src.add_argument("--pdf", help="PDF file to render and sample")
    ap.add_argument("--page", type=int, default=1, help="PDF page number (1-based)")
    ap.add_argument("--out", default="theme.json", help="Output theme JSON")
    ap.add_argument("--logo-dir", help="Directory to save a fetched logo into (URL only)")
    args = ap.parse_args(argv)

    org = fonts = logo = None
    import tempfile

    if args.image:
        img = Image.open(args.image)
        org = Path(args.image).stem.replace("_", " ")
    elif args.pdf:
        img = render_pdf_page(args.pdf, max(0, args.page - 1))
        org = Path(args.pdf).stem.replace("_", " ")
        fonts = pdf_fonts(args.pdf)
    else:  # url
        with tempfile.TemporaryDirectory() as td:
            shot = str(Path(td) / "page.png")
            screenshot_url(args.url, shot)
            full = Image.open(shot).copy()
        # Brand chrome (logo bar, nav, buttons) lives near the top; a full-page shot is
        # dominated by hero/content imagery. Sample the top header band for brand colour.
        w, h = full.size
        img = full.crop((0, 0, w, min(h, 360)))
        try:
            html = fetch(args.url)
            meta = url_metadata(args.url, html, args.logo_dir)
            org = meta.get("organization")
            fonts = meta.get("fonts")
            logo = meta.get("logo")
        except Exception as e:  # noqa: BLE001
            print(f"  ! could not read page metadata: {e}", file=sys.stderr)

    colors = map_colors(sample_palette(img))
    theme = build_theme(colors, org, fonts, logo)
    Path(args.out).write_text(json.dumps(theme, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {args.out}  (heuristic — review colors/fonts/logo)")
    print(json.dumps(theme, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
