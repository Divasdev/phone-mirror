#!/usr/bin/env python3
"""Builds the Phone Mirror website.

Puts every page in website/pages/ into the shared layout, fills in the facts of the current
download (version, size, fingerprint), and writes the finished site to dist/site/ together
with the download itself. Only Python's standard library is used.

    python3 website/build.py          # after ./release.sh has made dist/Phone-Mirror.dmg
"""

import hashlib
import pathlib
import plistlib
import re
import shutil
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
OUT = ROOT / "dist" / "site"
DMG = ROOT / "dist" / "Phone-Mirror.dmg"
INFO = ROOT / "Resources" / "Info.plist"

SITE_URL = "https://www.phonemirror.in"      # where the site lives (the address whose certificate works)

# The Apple logo shown on the "Download for Mac" buttons ({{apple}} in a page).
APPLE = ('<svg class="apple" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12.152 6.896c-.948 0-2.415'
         '-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 '
         '3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 '
         '1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559'
         '-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83'
         '-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>')
DOWNLOAD = "/download/Phone-Mirror.dmg"      # the download's address on the site


def fill(text, values):
    """Replaces {{name}} with its value. An unknown name stops the build."""
    def swap(match):
        name = match.group(1)
        if name not in values:
            sys.exit(f"Unknown placeholder {{{{{name}}}}}")
        return values[name]
    return re.sub(r"\{\{(\w+)\}\}", swap, text)


def minify_css(css):
    """Makes the stylesheet smaller without changing what it means: comments and line breaks
    go, and so do the spaces around braces and semicolons and after colons and commas."""
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    css = re.sub(r"\s+", " ", css)
    css = re.sub(r" ?([{};]) ?", r"\1", css)
    css = re.sub(r"([:,]) ", r"\1", css)
    return css.replace(";}", "}").strip()


def head_extras(about):
    """Lines for a page's <head> that only that page needs (set in the block at its top):
      italic: yes        the page shows the italic heading font above the fold
      lcp: /assets/...   the page's biggest picture, so the browser fetches it first"""
    lines = []
    if about.get("italic") == "yes":
        lines.append('<link rel="preload" href="/assets/fonts/InstrumentSerif-Italic.woff2" as="font" '
                     'type="font/woff2" crossorigin>')
    if about.get("lcp"):
        lines.append(f'<link rel="preload" href="{about["lcp"]}" as="image" fetchpriority="high">')
    return "".join(line + "\n" for line in lines)


def main():
    if not DMG.exists():
        sys.exit("Run ./release.sh first: dist/Phone-Mirror.dmg is not there yet.")

    with open(INFO, "rb") as file:
        version = plistlib.load(file)["CFBundleShortVersionString"]
    data = DMG.read_bytes()
    facts = {
        "version": version,
        "size": f"{round(len(data) / 1_048_576)} MB",
        "sha256": hashlib.sha256(data).hexdigest(),
        "download": DOWNLOAD,
        "apple": APPLE,
        "site_url": SITE_URL,
        "year": time.strftime("%Y"),
        "build": time.strftime("%Y%m%d%H%M"),   # makes browsers fetch the fresh script after a rebuild
    }

    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(SITE / "static", OUT)

    # The stylesheet travels inside every page: one request fewer before anything can be shown.
    facts["css"] = minify_css((OUT / "assets" / "site.css").read_text())
    (OUT / "assets" / "site.css").unlink()

    layout = (SITE / "layout.html").read_text()
    paths = []
    for page in sorted((SITE / "pages").glob("*.html")):
        text = page.read_text()
        header = re.match(r"\s*<!--(.*?)-->", text, re.S)
        if not header:
            sys.exit(f"{page.name} has no title/description/path block at the top")
        about = dict(line.split(":", 1) for line in header.group(1).strip().splitlines())
        about = {key.strip(): value.strip() for key, value in about.items()}
        body = fill(text[header.end():], facts)
        html = fill(layout, {**facts, **about, "head": head_extras(about), "content": body})

        path = about["path"]
        target = OUT / (path.lstrip("/") + "index.html" if path.endswith("/") else path.lstrip("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(html)
        if about.get("nav") != "none":
            paths.append(path)

    # The download itself, and the small files search engines and hosts look for.
    (OUT / "download").mkdir(exist_ok=True)
    shutil.copy2(DMG, OUT / DOWNLOAD.lstrip("/"))
    (OUT / "download" / "SHA256SUMS.txt").write_text(f"{facts['sha256']}  Phone-Mirror.dmg\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{SITE_URL}{path}</loc></url>\n" for path in paths) + "</urlset>\n")
    (OUT / ".nojekyll").write_text("")

    print(f"Built dist/site: version {facts['version']}, {facts['size']}, {len(paths)} pages")


if __name__ == "__main__":
    main()
