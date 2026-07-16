#!/usr/bin/env python3
"""Generate website/changelog.html from CHANGELOG.md.

CHANGELOG.md is the source of truth for release history. This script renders it
as a human-readable website page and can extract one release's notes for Sparkle
and GitHub Releases.

Usage:
    scripts/generate-changelog.py [CHANGELOG] [OUTPUT]
        CHANGELOG  default: CHANGELOG.md
        OUTPUT   default: website/changelog.html
    scripts/generate-changelog.py --release-notes VERSION OUTPUT
"""
import argparse
import html
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASE_HEADING = re.compile(r"^## \[(?P<version>[^\]]+)\](?: - (?P<date>\d{4}-\d{2}-\d{2}))?\s*$")


@dataclass
class Release:
    version: str
    date: str
    notes_md: str

    @property
    def date_value(self):
        if not self.date:
            return None
        try:
            return datetime.fromisoformat(self.date)
        except ValueError:
            return None


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
            tag = "h3" if len(heading.group(1)) <= 3 else "h4"
            out.append(f"<{tag}>{inline_md(heading.group(2))}</{tag}>")
        else:
            out.append(f"<p>{inline_md(line.strip())}</p>")
        i += 1
    return "\n".join(out)


def strip_blank_edges(lines):
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def parse_changelog(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    headings = [(i, RELEASE_HEADING.match(line)) for i, line in enumerate(lines)]
    headings = [(i, match) for i, match in headings if match]
    releases = []

    for idx, (start, match) in enumerate(headings):
        end = headings[idx + 1][0] if idx + 1 < len(headings) else len(lines)
        version = match.group("version").strip()
        if version.lower() == "unreleased":
            continue
        section = strip_blank_edges(lines[start + 1:end])
        releases.append(Release(
            version=version,
            date=match.group("date") or "",
            notes_md="\n".join(section).strip(),
        ))

    return releases


def fmt_date(value):
    dt = value if isinstance(value, datetime) else None
    if dt is None and isinstance(value, str) and value:
        try:
            dt = datetime.fromisoformat(value)
        except ValueError:
            dt = None
    if not dt:
        return ""
    return dt.strftime("%-d %B, %Y")


def is_prerelease(short):
    return any(c.isalpha() for c in short)


def render(items):
    rows = []
    for it in items:
        badge = '<span class="badge">Pre-release</span>' if is_prerelease(it.version) else ""
        meta = fmt_date(it.date_value or it.date)
        notes = md_to_html(it.notes_md) if it.notes_md else '<p class="empty">No release notes.</p>'
        rows.append(f"""    <section class="release">
      <div class="release-heading">
        <h2>{html.escape(it.version)}{badge}</h2>
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

  <meta property="og:type" content="website">
  <meta property="og:url" content="https://takes.nigelwarren.com/changelog.html">
  <meta property="og:title" content="Takes for Mac - Release Notes">
  <meta property="og:description" content="Takes is a macOS app for comparing audio tracks with instant A/B switching, waveform alignment, and blind listening mode.">
  <meta property="og:image" content="https://takes.nigelwarren.com/social_preview.jpg">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">

  <meta name="theme-color" content="#fbfbfd">
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <script>
    (() => {{
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      document.documentElement.dataset.theme = prefersDark ? "dark" : "light";
    }})();
  </script>
  <link rel="stylesheet" href="styles.css">
</head>
<body class="changelog-page">
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
      <p>Everything shipped in Takes for Mac, newest at the top.</p>
    </header>
{body}
    <footer class="footer">
      <span>Made with 🥱 sleep deprivation by <a href="https://nigelwarren.com">Nigel M. Warren</a>. &copy; 2026.</span>
    </footer>
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

      function runThemeTransition(nextTheme) {{
        document.startViewTransition(() => {{
          applyTheme(nextTheme);
        }});
      }}

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
        runThemeTransition(root.dataset.theme === "dark" ? "light" : "dark");
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


def release_notes_markdown(changelog_path, version):
    for release in parse_changelog(changelog_path):
        if release.version == version:
            notes = release.notes_md.strip()
            if not notes:
                sys.exit(f"release {version} has no notes in {changelog_path}")
            # GitHub releases and Sparkle notes are not nested inside the
            # CHANGELOG release heading, so promote category headings by one.
            return re.sub(r"^### ", "## ", notes, flags=re.MULTILINE)
    sys.exit(f"release {version} not found in {changelog_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--release-notes", metavar="VERSION")
    args = parser.parse_args()

    if args.release_notes:
        if len(args.paths) > 1:
            parser.error("--release-notes accepts at most one output path")
        changelog_path = ROOT / "CHANGELOG.md"
        output_path = Path(args.paths[0]) if args.paths else None
        notes = release_notes_markdown(changelog_path, args.release_notes)
        if output_path:
            output_path.write_text(notes + "\n", encoding="utf-8")
            print(f"wrote {output_path}")
        else:
            print(notes)
        return

    if len(args.paths) > 2:
        parser.error("expected [CHANGELOG] [OUTPUT]")

    changelog_path = Path(args.paths[0]) if args.paths else ROOT / "CHANGELOG.md"
    output_path = Path(args.paths[1]) if len(args.paths) > 1 else ROOT / "website" / "changelog.html"
    if not changelog_path.exists():
        sys.exit(f"changelog not found: {changelog_path}")
    output_path.write_text(render(parse_changelog(changelog_path)), encoding="utf-8")
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
