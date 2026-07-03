#!/usr/bin/env python3
"""Generate website/changelog.html from the Sparkle appcast.

The appcast is the source of truth for release history: each <item> carries the
version, date, and release notes (the <description>, authored in Markdown). This
renders them as a single self-contained, human-readable page.

Usage:
    scripts/generate-changelog.py [APPCAST] [OUTPUT]
        APPCAST  default: website/appcast.xml
        OUTPUT   default: website/changelog.html
"""
import html
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "Nigelw/Takes"

ROOT = Path(__file__).resolve().parent.parent
appcast_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "website" / "appcast.xml"
output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "website" / "changelog.html"


def text(item, tag, ns=None):
    el = item.find(f"{{{ns}}}{tag}" if ns else tag)
    return el.text.strip() if el is not None and el.text else ""


def inline_md(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    return s


def md_to_html(md):
    """Render the small Markdown subset used by release notes (bullet lists,
    h2/h3 headings, paragraphs) to HTML. Other formats are passed through."""
    out, in_list = [], False
    for raw in md.splitlines():
        line = raw.rstrip()
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        heading = re.match(r"^(#{2,})\s+(.*)$", line)
        if bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline_md(bullet.group(1))}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if not line.strip():
            continue
        if heading:
            tag = "h3" if len(heading.group(1)) == 2 else "h4"
            out.append(f"<{tag}>{inline_md(heading.group(2))}</{tag}>")
        else:
            out.append(f"<p>{inline_md(line.strip())}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def notes_html(item):
    # Release notes are authored in Markdown and embedded in the appcast as
    # <description sparkle:format="markdown">; render that to HTML.
    desc = item.find("description")
    if desc is None or not desc.text:
        return ""
    return md_to_html(desc.text.strip())


def parse_date(value):
    if not value:
        return None
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        return datetime.fromisoformat(value)
    except ValueError:
        try:
            return parsedate_to_datetime(value)
        except (TypeError, ValueError):
            return None


def parse_items(appcast):
    tree = ET.parse(appcast)
    items = []
    for item in tree.findall(".//item"):
        build = text(item, "version", SPARKLE)
        date = text(item, "pubDate")
        short = text(item, "shortVersionString", SPARKLE) or text(item, "title")
        items.append({
            "build": int(build) if build.isdigit() else 0,
            "short": short,
            "min_os": text(item, "minimumSystemVersion", SPARKLE),
            "date": date,
            "date_value": parse_date(date),
            "notes": notes_html(item),  # HTML, rendered from Markdown when needed
            "tag": f"v{short}" if short else "",
        })
    # Newest first by publication date.
    items.sort(key=sort_key, reverse=True)
    return items


def github_release_items():
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{REPO}/releases", "--paginate"],
            capture_output=True,
            check=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return []

    try:
        releases = json.loads(result.stdout)
    except json.JSONDecodeError:
        return []

    items = []
    for release in releases:
        if release.get("draft"):
            continue
        tag = release.get("tag_name", "")
        short = tag.removeprefix("v") or release.get("name", "")
        published = release.get("published_at") or release.get("created_at") or ""
        body = (release.get("body") or "").strip()
        items.append({
            "build": 0,
            "short": short,
            "min_os": "",
            "date": published,
            "date_value": parse_date(published),
            "notes": md_to_html(body) if body else "",
            "tag": tag,
        })
    return items


def combined_items(appcast):
    items = parse_items(appcast)
    seen = {item["tag"] or item["short"] for item in items}
    for item in github_release_items():
        key = item["tag"] or item["short"]
        if key in seen:
            continue
        items.append(item)
        seen.add(key)
    items.sort(key=sort_key, reverse=True)
    return items


def sort_key(item):
    return item.get("date_value") or datetime.min.replace(tzinfo=timezone.utc)


def fmt_date(value):
    dt = value if isinstance(value, datetime) else parse_date(value)
    if not dt:
        return ""
    return dt.strftime("%-d %B, %Y")


def is_prerelease(short):
    return any(c.isalpha() for c in short)


def render(items):
    rows = []
    for it in items:
        badge = '<span class="badge">Pre-release</span>' if is_prerelease(it["short"]) else ""
        meta = fmt_date(it.get("date_value") or it["date"])
        notes = it["notes"] or '<p class="empty">No release notes.</p>'
        rows.append(f"""    <section class="release">
      <div class="release-heading">
        <h2>{html.escape(it['short'])}{badge}</h2>
        <p class="meta">{html.escape(meta)}</p>
      </div>
      <div class="notes">{notes}</div>
    </section>""")
    body = "\n".join(rows) if rows else '      <p class="empty">No releases yet.</p>'
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Takes — Changelog</title>
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <style>
    :root {{
      color-scheme: light dark;
      --ink: #1d1d1f;
      --muted: #6e6e73;
      --line: #e5e5e7;
      --accent: #4f3ec6;
      --surface: #fbfbfd;
    }}
    * {{ box-sizing: border-box; }}
    body {{ font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           margin: 0; color: var(--ink); background: var(--surface); }}
    a {{ color: inherit; text-decoration: none; }}
    .nav {{ align-items: center; display: flex; justify-content: space-between;
            margin: 0 auto; max-width: 48rem; padding: 1.25rem; }}
    .brand {{ align-items: center; display: inline-flex; gap: .65rem; font-size: .95rem; font-weight: 700; }}
    .brand img {{ width: 34px; height: 34px; border-radius: 9px; }}
    .nav-links {{ align-items: center; color: var(--muted); display: flex; gap: 1rem; font-size: .88rem; font-weight: 600; }}
    .nav-links a[aria-current="page"] {{ color: var(--accent); }}
    .brand:hover, .nav-links a:hover {{ color: var(--accent); }}
    .page {{ max-width: 48rem; margin: 0 auto; padding: 0 1.25rem 5rem; }}
    .hero {{ padding: 3.2rem 0 2.4rem; }}
    .hero h1 {{ font-size: clamp(2.4rem, 8vw, 3.9rem); letter-spacing: 0; line-height: .98; margin: 0; }}
    .hero p {{ color: var(--muted); font-size: clamp(1.05rem, 2.5vw, 1.35rem); line-height: 1.35;
               margin: 1rem 0 0; max-width: 34rem; }}
    .release {{ padding: 1.5rem 0; border-top: 1px solid var(--line); }}
    .release:first-of-type {{ border-top: none; }}
    .release-heading {{ align-items: center; display: flex; gap: 1rem; justify-content: space-between; margin: 0 0 .75rem; }}
    .release h2 {{ font-size: 1.2rem; margin: 0; display: flex; align-items: baseline; gap: .6rem; }}
    .meta {{ color: var(--muted); flex: 0 0 auto; font-size: .85rem; margin: 0; text-align: right; }}
    .badge {{ font-size: .65rem; font-weight: 600; text-transform: uppercase; letter-spacing: .04em;
             color: #b25000; background: #ffefe0; padding: .15rem .45rem; border-radius: 5px; }}
    .notes ul {{ margin: 0; padding-left: 1.25rem; }}
    .notes li {{ margin: .2rem 0; }}
    .notes h3, .notes h4 {{ font-size: .95rem; margin: 1rem 0 .35rem; }}
    .notes > :first-child {{ margin-top: 0; }}
    .empty {{ color: #8e8e93; font-style: italic; }}
    footer {{ margin-top: 3rem; font-size: .85rem; color: var(--muted); }}
    footer a {{ color: inherit; }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --ink: #f5f5f7;
        --muted: #98989d;
        --line: #2c2c2e;
        --accent: #a79dff;
        --surface: #111114;
      }}
      .release {{ border-color: var(--line); }}
      .badge {{ color: #ffb066; background: #3a2410; }}
    }}
    @media (max-width: 440px) {{
      .release-heading {{ align-items: flex-start; flex-direction: column; gap: .15rem; }}
      .meta {{ text-align: left; }}
    }}
  </style>
</head>
<body>
  <nav class="nav" aria-label="Main navigation">
    <a class="brand" href="index.html" aria-label="Takes homepage">
      <img src="icon.png" alt="">
      <span>Takes</span>
    </a>
    <div class="nav-links">
      <a href="changelog.html" aria-current="page">Changelog</a>
      <a href="https://github.com/Nigelw/Takes">GitHub</a>
    </div>
  </nav>
  <main class="page">
    <header class="hero">
      <h1>Changelog</h1>
      <p>Everything shipped in Takes for Mac, newest first.</p>
    </header>
{body}
  </main>
</body>
</html>
"""


def main():
    if not appcast_path.exists():
        sys.exit(f"appcast not found: {appcast_path}")
    output_path.write_text(render(combined_items(appcast_path)))
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
