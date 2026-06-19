#!/usr/bin/env python3
"""Backfill appcast <description> release notes from GitHub releases.

For each <item> in the appcast, fetches the matching GitHub release's notes
(tag = v<shortVersionString>), renders them to HTML via GitHub's Markdown API,
and writes them into the item's <description>. Use this for releases that
predate the --notes-file flow; new releases already embed their notes.

By default only items missing a description are filled; pass --force to
overwrite existing ones (e.g. after editing notes on GitHub).

After running this, regenerate the changelog:
    scripts/generate-changelog.py

Usage:
    scripts/backfill-notes.py [--force] [APPCAST]
        APPCAST  default: website/appcast.xml
"""
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "Nigelw/Takes"
ROOT = Path(__file__).resolve().parent.parent

ET.register_namespace("sparkle", SPARKLE)  # keep the sparkle: prefix on write


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    return (r.returncode, r.stdout, r.stderr)


def release_body(tag):
    code, out, _ = gh("release", "view", tag, "--repo", REPO, "--json", "body", "-q", ".body")
    return out.strip() if code == 0 else None


def render_markdown(md):
    code, out, err = gh("api", "-X", "POST", "/markdown", "-f", f"text={md}", "-f", "mode=gfm")
    if code != 0:
        sys.exit(f"markdown render failed: {err.strip()}")
    return out.strip()


def main():
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    appcast = Path(args[0]) if args else ROOT / "website" / "appcast.xml"
    if not appcast.exists():
        sys.exit(f"appcast not found: {appcast}")

    tree = ET.parse(appcast)
    ns = {"sparkle": SPARKLE}
    changed = 0

    for item in tree.findall(".//item"):
        short_el = item.find("sparkle:shortVersionString", ns)
        if short_el is None or not short_el.text:
            continue
        short = short_el.text.strip()
        tag = f"v{short}"

        desc = item.find("description")
        has_notes = desc is not None and (desc.text or "").strip()
        if has_notes and not force:
            print(f"  {tag}: already has notes — skipping (use --force to overwrite)")
            continue

        body = release_body(tag)
        if not body:
            print(f"  {tag}: no GitHub release body — skipping")
            continue

        html = render_markdown(body)
        if desc is None:
            desc = ET.SubElement(item, "description")
        desc.text = html
        changed += 1
        print(f"  {tag}: backfilled {len(html)} chars of notes")

    if changed:
        tree.write(appcast, encoding="utf-8", xml_declaration=True)
        print(f"updated {appcast} ({changed} item(s)). Now run scripts/generate-changelog.py")
    else:
        print("no changes")


if __name__ == "__main__":
    main()
