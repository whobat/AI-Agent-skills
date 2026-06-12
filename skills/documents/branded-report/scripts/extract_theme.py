#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Extract a branded-report theme (colors + fonts + logo) from an Office template
(.pptx / .potx / .thmx / .dotx) into a theme.json that build_report.py can use.

  python extract_theme.py --template Brand.pptx --out theme.json --logo-dir ./assets

It reads the OOXML theme (ppt/theme/theme1.xml or theme/theme/themeN.xml): the color
scheme (accent1..6, dk2, lt2) and the major/minor font, and copies the template's logo
candidates out so the report can embed them. The mapping to report roles is a sensible
default you can hand-tune afterwards.

Deterministic; no LLM. Only needs the Python standard library.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"


def _theme_xml(zf):
    names = [n for n in zf.namelist() if re.search(r"theme/theme\d+\.xml$", n)]
    if not names:
        raise SystemExit("No theme XML found in the template (looked for */theme/themeN.xml).")
    # Prefer the slide/document master theme: theme1.xml.
    names.sort(key=lambda n: (not n.endswith("theme1.xml"), n))
    return zf.read(names[0])


def _scheme_color(clr_scheme, key):
    node = clr_scheme.find(f"{A}{key}")
    if node is None:
        return None
    srgb = node.find(f"{A}srgbClr")
    if srgb is not None:
        return "#" + srgb.get("val").upper()
    sysclr = node.find(f"{A}sysClr")
    if sysclr is not None and sysclr.get("lastClr"):
        return "#" + sysclr.get("lastClr").upper()
    return None


def extract(template_path, logo_dir):
    zf = zipfile.ZipFile(template_path)
    root = ET.fromstring(_theme_xml(zf))
    elements = root.find(f"{A}themeElements")
    clr = elements.find(f"{A}clrScheme") if elements is not None else None
    fonts = elements.find(f"{A}fontScheme") if elements is not None else None
    if clr is None or fonts is None:
        raise SystemExit("Template theme XML is missing a colour or font scheme — cannot extract.")

    colors_raw = {k: _scheme_color(clr, k) for k in
                  ("dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3",
                   "accent4", "accent5", "accent6")}

    def first(*keys, default):
        for k in keys:
            if colors_raw.get(k):
                return colors_raw[k]
        return default

    # Map OOXML theme slots to report roles (tunable afterwards).
    colors = {
        "primary": first("accent1", default="#1F3A5F"),
        "secondary": first("accent2", default="#3E6B89"),
        "accent": first("accent3", "accent2", default="#5FA8D3"),
        "light": first("accent6", "accent5", "lt2", default="#EEF3F7"),
        "border": first("accent4", "accent5", default="#C9D6E0"),
        "muted": first("dk2", default="#4A4A4A"),
        "text": first("dk1", default="#2B2B2B"),
    }
    if colors["text"] in ("#000000", "#FFFFFF"):
        colors["text"] = "#2B2B2B"

    major = fonts.find(f"{A}majorFont/{A}latin")
    minor = fonts.find(f"{A}minorFont/{A}latin")
    major_tf = major.get("typeface") if major is not None and major.get("typeface") else "Georgia"
    minor_tf = minor.get("typeface") if minor is not None and minor.get("typeface") else "Georgia"

    theme = {
        "organization": Path(template_path).stem.replace("_", " "),
        "colors": colors,
        "fonts": {"heading": f"{major_tf}, serif", "body": f"{minor_tf}, serif",
                  "mono": "Consolas, monospace"},
        "logo": None,
    }

    # Copy logo candidates: prefer a colored vector, also a raster (for DOCX).
    media = [n for n in zf.namelist() if "/media/" in n and
             n.lower().endswith((".svg", ".png", ".jpg", ".jpeg"))]
    if media and logo_dir:
        logo_dir = Path(logo_dir)
        logo_dir.mkdir(parents=True, exist_ok=True)
        # Heuristic: smallest few SVGs are usually logos/wordmarks; copy up to 4 svg + 2 raster.
        svgs = sorted([m for m in media if m.lower().endswith(".svg")],
                      key=lambda m: zf.getinfo(m).file_size)[:4]
        rasters = sorted([m for m in media if m.lower().endswith((".png", ".jpg", ".jpeg"))],
                         key=lambda m: zf.getinfo(m).file_size)[:2]
        copied = []
        for m in svgs + rasters:
            dest = logo_dir / Path(m).name
            dest.write_bytes(zf.read(m))
            copied.append(str(dest))
        if copied:
            theme["logo"] = copied[0]  # first SVG by default
            theme["_logo_candidates"] = copied
            print(f"  copied {len(copied)} logo candidate(s) to {logo_dir} — "
                  f"set theme['logo'] to the one you want (currently {Path(copied[0]).name}).",
                  file=sys.stderr)
    return theme


def main(argv=None):
    ap = argparse.ArgumentParser(description="Extract a branded-report theme from an Office template.")
    ap.add_argument("--template", required=True, help=".pptx/.potx/.thmx/.dotx file")
    ap.add_argument("--out", default="theme.json", help="Output theme JSON path")
    ap.add_argument("--logo-dir", help="Directory to copy logo candidates into")
    args = ap.parse_args(argv)

    theme = extract(args.template, args.logo_dir)
    Path(args.out).write_text(json.dumps(theme, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Wrote {args.out}")
    print(json.dumps({k: v for k, v in theme.items() if k != "_logo_candidates"},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
