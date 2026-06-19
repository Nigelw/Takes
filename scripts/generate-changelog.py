#!/usr/bin/env python3
"""Generate website/changelog.html from the Sparkle appcast.

The appcast is the source of truth for release history: each <item> carries the
version, date, and release notes (the <description> HTML). This renders them as
a single self-contained, human-readable page.

Usage:
    scripts/generate-changelog.py [APPCAST] [OUTPUT]
        APPCAST  default: website/appcast.xml
        OUTPUT   default: website/changelog.html
"""
import html
import sys
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

ROOT = Path(__file__).resolve().parent.parent
appcast_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "website" / "appcast.xml"
output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "website" / "changelog.html"


def text(item, tag, ns=None):
    el = item.find(f"{{{ns}}}{tag}" if ns else tag)
    return el.text.strip() if el is not None and el.text else ""


def parse_items(appcast):
    tree = ET.parse(appcast)
    items = []
    for item in tree.findall(".//item"):
        build = text(item, "version", SPARKLE)
        items.append({
            "build": int(build) if build.isdigit() else 0,
            "short": text(item, "shortVersionString", SPARKLE) or text(item, "title"),
            "min_os": text(item, "minimumSystemVersion", SPARKLE),
            "date": text(item, "pubDate"),
            "notes": text(item, "description"),  # CDATA HTML, may be empty
        })
    # Newest first by build number (Sparkle's comparison key).
    items.sort(key=lambda i: i["build"], reverse=True)
    return items


def fmt_date(rfc822):
    if not rfc822:
        return ""
    try:
        return parsedate_to_datetime(rfc822).strftime("%B %-d, %Y")
    except (TypeError, ValueError):
        return rfc822


def is_prerelease(short):
    return any(c.isalpha() for c in short)


def render(items):
    rows = []
    for it in items:
        badge = '<span class="badge">Pre-release</span>' if is_prerelease(it["short"]) else ""
        meta = " · ".join(p for p in [fmt_date(it["date"]),
                                      f"build {it['build']}" if it["build"] else ""] if p)
        notes = it["notes"] or '<p class="empty">No release notes.</p>'
        rows.append(f"""    <section class="release">
      <h2>{html.escape(it['short'])}{badge}</h2>
      <p class="meta">{html.escape(meta)}</p>
      <div class="notes">{notes}</div>
    </section>""")
    body = "\n".join(rows) if rows else '    <p class="empty">No releases yet.</p>'
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Takes — Changelog</title>
  <style>
    :root {{ color-scheme: light dark; }}
    body {{ font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           max-width: 44rem; margin: 0 auto; padding: 3rem 1.25rem 5rem; color: #1d1d1f; }}
    header {{ display: flex; align-items: center; gap: .75rem; margin-bottom: 2.5rem; }}
    header img {{ width: 48px; height: 48px; border-radius: 11px; }}
    header h1 {{ font-size: 1.5rem; margin: 0; }}
    .release {{ padding: 1.5rem 0; border-top: 1px solid #e5e5e7; }}
    .release:first-of-type {{ border-top: none; }}
    .release h2 {{ font-size: 1.2rem; margin: 0 0 .25rem; display: flex; align-items: baseline; gap: .6rem; }}
    .meta {{ color: #6e6e73; font-size: .85rem; margin: 0 0 .75rem; }}
    .badge {{ font-size: .65rem; font-weight: 600; text-transform: uppercase; letter-spacing: .04em;
             color: #b25000; background: #ffefe0; padding: .15rem .45rem; border-radius: 5px; }}
    .notes ul {{ margin: 0; padding-left: 1.25rem; }}
    .notes li {{ margin: .2rem 0; }}
    .notes h3, .notes h4 {{ font-size: .95rem; margin: 1rem 0 .35rem; }}
    .notes > :first-child {{ margin-top: 0; }}
    .empty {{ color: #8e8e93; font-style: italic; }}
    footer {{ margin-top: 3rem; font-size: .85rem; color: #6e6e73; }}
    footer a {{ color: inherit; }}
    @media (prefers-color-scheme: dark) {{
      body {{ color: #f5f5f7; }}
      .release {{ border-color: #2c2c2e; }}
      .meta, footer {{ color: #98989d; }}
      .badge {{ color: #ffb066; background: #3a2410; }}
    }}
  </style>
</head>
<body>
  <header>
    <img src="icon.png" alt="Takes icon">
    <h1>Takes — Changelog</h1>
  </header>
{body}
  <footer>
    <a href="https://github.com/Nigelw/Takes/releases">All releases on GitHub</a>
  </footer>
</body>
</html>
"""


def main():
    if not appcast_path.exists():
        sys.exit(f"appcast not found: {appcast_path}")
    output_path.write_text(render(parse_items(appcast_path)))
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
