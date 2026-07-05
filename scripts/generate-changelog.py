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


def render_list(lines, i, indent):
    """Render a run of bullet lines starting at lines[i] into a <ul>, recursing
    into more-indented lines as nested sub-lists. Returns (html, next_index)."""
    items = []
    while i < len(lines):
        indent_str, text_ = lines[i]
        if indent_str is None or len(indent_str) < indent:
            break
        if len(indent_str) > indent:
            sub_html, i = render_list(lines, i, len(indent_str))
            items[-1] = items[-1][:-len("</li>")] + sub_html + "</li>"
            continue
        items.append(f"<li>{inline_md(text_)}</li>")
        i += 1
    return "<ul>" + "".join(items) + "</ul>", i


def md_to_html(md):
    """Render the small Markdown subset used by release notes (nested bullet
    lists, h2/h3 headings, paragraphs) to HTML. Other formats are passed through."""
    out = []
    lines = md.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        bullet = re.match(r"^(\s*)[-*]\s+(.*)$", line)
        heading = re.match(r"^(#{2,})\s+(.*)$", line)
        if bullet:
            bullet_lines = []
            j = i
            while j < len(lines):
                m = re.match(r"^(\s*)[-*]\s+(.*)$", lines[j].rstrip())
                if not m:
                    break
                bullet_lines.append((m.group(1), m.group(2)))
                j += 1
            list_html, _ = render_list(bullet_lines, 0, 0)
            out.append(list_html)
            i = j
            continue
        if not line.strip():
            i += 1
            continue
        if heading:
            tag = "h3" if len(heading.group(1)) == 2 else "h4"
            out.append(f"<{tag}>{inline_md(heading.group(2))}</{tag}>")
        else:
            out.append(f"<p>{inline_md(line.strip())}</p>")
        i += 1
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
  <title>Takes — Release Notes</title>
  <meta name="theme-color" content="#fbfbfd">
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <script>
    (() => {{
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      document.documentElement.dataset.theme = prefersDark ? "dark" : "light";
    }})();
  </script>
  <style>
    :root {{
      color-scheme: light dark;
      --ink: #1d1d1f;
      --muted: #6e6e73;
      --line: #e5e5e7;
      --accent: #4f3ec6;
      --surface: #fbfbfd;
      --menu-bg: rgba(255, 255, 255, 0.96);
      --theme-toggle-bg: rgba(255, 255, 255, 0.72);
      --theme-toggle-hover: rgba(238, 234, 255, 0.9);
      --theme-toggle-icon: #4f3ec6;
      --theme-toggle-shadow: 0 10px 24px rgba(40, 30, 90, 0.12);
    }}
    html[data-theme="dark"] {{
      --ink: #f5f5f7;
      --muted: #98989d;
      --line: #2c2c2e;
      --accent: #a79dff;
      --surface: #111114;
      --menu-bg: rgba(24, 24, 28, 0.97);
      --theme-toggle-bg: rgba(32, 28, 48, 0.82);
      --theme-toggle-hover: rgba(54, 47, 78, 0.95);
      --theme-toggle-icon: #ffd083;
      --theme-toggle-shadow: 0 12px 26px rgba(0, 0, 0, 0.34);
    }}
    * {{ box-sizing: border-box; }}
    body {{ font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
           margin: 0; color: var(--ink); background: var(--surface); }}
    a {{ color: inherit; text-decoration: none; }}
    .nav {{ align-items: center; display: flex; justify-content: space-between;
            margin: 0 auto; max-width: 48rem; padding: 1.25rem; }}
    .brand {{ align-items: center; display: inline-flex; gap: .65rem; font-size: .95rem; font-weight: 700; }}
    .brand img {{ width: 34px; height: 34px; border-radius: 9px; }}
    .nav-actions {{ align-items: center; display: flex; gap: .8rem; position: relative; }}
    .nav-links {{ align-items: center; color: var(--muted); display: flex; gap: 1rem; font-size: .88rem; font-weight: 600; }}
    .nav-links a[aria-current="page"] {{ color: var(--accent); }}
    .brand:hover, .nav-links a:hover {{ color: var(--accent); }}
    .nav-menu-button {{ display: none; }}
    .nav-menu-icon,
    .nav-menu-icon::before,
    .nav-menu-icon::after {{
      background: currentColor;
      border-radius: 999px;
      display: block;
      height: 2px;
      width: 16px;
    }}
    .nav-menu-icon {{ position: relative; }}
    .nav-menu-icon::before,
    .nav-menu-icon::after {{
      content: "";
      left: 0;
      position: absolute;
    }}
    .nav-menu-icon::before {{ top: -5px; }}
    .nav-menu-icon::after {{ top: 5px; }}
    .theme-toggle {{
      align-items: center;
      appearance: none;
      background: var(--theme-toggle-bg);
      border: 1px solid var(--line);
      border-radius: 999px;
      box-shadow: var(--theme-toggle-shadow);
      color: var(--theme-toggle-icon);
      cursor: pointer;
      display: inline-flex;
      height: 38px;
      justify-content: center;
      padding: 0;
      width: 38px;
    }}
    .theme-toggle:hover {{ background: var(--theme-toggle-hover); }}
    .theme-toggle:focus-visible {{
      outline: 3px solid rgba(107, 85, 240, 0.35);
      outline-offset: 3px;
    }}
    .theme-toggle svg {{ height: 18px; width: 18px; }}
    .theme-toggle .moon-icon {{ display: block; }}
    .theme-toggle .sun-icon {{ display: none; }}
    html[data-theme="dark"] .theme-toggle .moon-icon {{ display: none; }}
    html[data-theme="dark"] .theme-toggle .sun-icon {{ display: block; }}
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
    .notes li ul {{ margin-top: .2rem; }}
    .notes h3, .notes h4 {{ font-size: .95rem; margin: 1rem 0 .35rem; }}
    .notes > :first-child {{ margin-top: 0; }}
    .empty {{ color: #8e8e93; font-style: italic; }}
    footer {{ margin-top: 3rem; font-size: .85rem; color: var(--muted); }}
    footer a {{ color: inherit; }}
    html[data-theme="dark"] .release {{ border-color: var(--line); }}
    html[data-theme="dark"] .badge {{ color: #ffb066; background: #3a2410; }}
    @media (max-width: 560px) {{
      .nav-menu-button {{
        align-items: center;
        appearance: none;
        background: var(--menu-bg);
        border: 1px solid var(--line);
        border-radius: 999px;
        color: var(--muted);
        cursor: pointer;
        display: inline-flex;
        font-family: inherit;
        font-weight: 700;
        height: 38px;
        justify-content: center;
        min-height: 38px;
        padding: 0;
        width: 38px;
      }}
      .nav.menu-open .nav-menu-button {{ color: var(--accent); }}
      .nav-actions .nav-links {{
        background: var(--menu-bg);
        border: 1px solid var(--line);
        border-radius: 8px;
        box-shadow: 0 12px 28px rgba(0, 0, 0, .12);
        display: none;
        min-width: 150px;
        padding: .45rem;
        position: absolute;
        right: 0;
        top: calc(100% + 8px);
        z-index: 10;
      }}
      .nav.menu-open .nav-actions .nav-links {{
        align-items: stretch;
        display: grid;
        gap: .1rem;
      }}
      .nav-actions .nav-links a {{
        border-radius: 6px;
        padding: .55rem .6rem;
      }}
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
    <div class="nav-actions">
      <button class="theme-toggle" type="button" aria-label="Switch to dark mode" aria-pressed="false">
        <svg class="moon-icon" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M20.4 14.7A8.5 8.5 0 0 1 9.3 3.6 8.5 8.5 0 1 0 20.4 14.7Z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>
        </svg>
        <svg class="sun-icon" viewBox="0 0 24 24" aria-hidden="true">
          <circle cx="12" cy="12" r="4.2" fill="none" stroke="currentColor" stroke-width="2"/>
          <path d="M12 2.5v2.2M12 19.3v2.2M4.7 4.7l1.6 1.6M17.7 17.7l1.6 1.6M2.5 12h2.2M19.3 12h2.2M4.7 19.3l1.6-1.6M17.7 6.3l1.6-1.6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
        </svg>
      </button>
      <button class="nav-menu-button" type="button" aria-label="Open navigation menu" aria-expanded="false" aria-controls="site-menu"><span class="nav-menu-icon" aria-hidden="true"></span></button>
      <div class="nav-links" id="site-menu">
        <a href="support.html">Support</a>
        <a href="changelog.html" aria-current="page">Release Notes</a>
        <a href="https://github.com/Nigelw/Takes">GitHub</a>
      </div>
    </div>
  </nav>
  <main class="page">
    <header class="hero">
      <h1>Release Notes</h1>
      <p>Everything shipped in Takes for Mac, newest first.</p>
    </header>
{body}
  </main>
  <script>
    (() => {{
      const root = document.documentElement;
      const nav = document.querySelector(".nav");
      const themeToggle = document.querySelector(".theme-toggle");
      const menuButton = document.querySelector(".nav-menu-button");
      const themeColor = document.querySelector('meta[name="theme-color"]');
      const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
      let hasManualTheme = false;

      const themeMetaColors = {{
        light: "#fbfbfd",
        dark: "#111114"
      }};

      function applyTheme(theme) {{
        const isDark = theme === "dark";
        root.dataset.theme = theme;
        themeToggle?.setAttribute("aria-pressed", String(isDark));
        themeToggle?.setAttribute("aria-label", isDark ? "Switch to light mode" : "Switch to dark mode");
        if (themeToggle) {{
          themeToggle.title = isDark ? "Switch to light mode" : "Switch to dark mode";
        }}
        themeColor?.setAttribute("content", themeMetaColors[theme]);
      }}

      applyTheme(root.dataset.theme || (mediaQuery.matches ? "dark" : "light"));

      themeToggle?.addEventListener("click", () => {{
        hasManualTheme = true;
        applyTheme(root.dataset.theme === "dark" ? "light" : "dark");
      }});

      menuButton?.addEventListener("click", () => {{
        const isOpen = nav?.classList.toggle("menu-open") ?? false;
        menuButton.setAttribute("aria-expanded", String(isOpen));
        menuButton.setAttribute("aria-label", isOpen ? "Close navigation menu" : "Open navigation menu");
      }});

      nav?.querySelectorAll(".nav-links a").forEach((link) => {{
        link.addEventListener("click", () => {{
          nav.classList.remove("menu-open");
          menuButton?.setAttribute("aria-expanded", "false");
          menuButton?.setAttribute("aria-label", "Open navigation menu");
        }});
      }});

      mediaQuery.addEventListener("change", (event) => {{
        if (!hasManualTheme) {{
          applyTheme(event.matches ? "dark" : "light");
        }}
      }});
    }})();
  </script>
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
