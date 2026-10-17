#!/usr/bin/env python3
"""Builds the Phone Mirror website.

Puts every page in website/pages/ into the shared layout, fills in the facts of the current
download (version, size, fingerprint), and writes the finished site to dist/site/ together
with the download itself. Only Python's standard library is used.

    python3 website/build.py          # after ./release.sh has made dist/Phone-Mirror.dmg
"""

import hashlib
import html
import json
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

# What search engines may do with a page, unless the page says otherwise (robots: in the block at its top).
ROBOTS = "index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1"

# The app in one sentence and as a list, for search engines and AI assistants (see schema() below).
# Like everything on the site, it may only say what the app does today.
SUMMARY = ("Phone Mirror is a Mac menu bar app for Android screen mirroring. It shows your Android phone's "
           "screen in a window on your Mac, over a USB cable or Wi-Fi, and you control the phone with the "
           "Mac's keyboard and pointer.")
FEATURES = [
    "Mirror an Android phone's screen in a window on the Mac, over a USB cable or Wi-Fi",
    "Control the phone with the Mac's keyboard and pointer, and copy and paste between the two",
    "Receive files from the phone with Quick Share, with no cable and nothing installed on the phone",
    "Drag files and folders both ways between the Mac and the phone",
    "Pocket mode: the phone's own screen stays dark while you use it from the Mac",
    "Wireless over home Wi-Fi or the phone's own hotspot",
    "Live frame rate and connection quality in the menu",
    "No account, and the only thing sent is an anonymous usage count once a day, which can be switched off",
]


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


def plain(piece):
    """The words of a piece of a page, without its tags."""
    words = re.sub(r"<[^>]+>", " ", piece)
    words = re.sub(r"\s+", " ", html.unescape(words)).strip()
    return re.sub(r" ([.,:;!?)])", r"\1", words)


def questions(body):
    """The questions and answers in a page's question lists (class "faq"), in plain words."""
    found = []
    for block in re.findall(r'<div class="faq">(.*?)</div>', body, re.S):
        for question, answer in re.findall(r"<summary>(.*?)</summary>(.*?)</details>", block, re.S):
            found.append((plain(question), plain(answer)))
    return found


def steps(body):
    """The numbered steps of a page's guide (class "card step"): each one's heading and its words.
    A step whose words only make sense with its picture or its lists says it again in data-howto."""
    found = []
    pattern = r'<div class="card step[^"]*"(?: data-howto="([^"]*)")?>\s*<div class="words">(.*?)</div>'
    for told, words in re.findall(pattern, body, re.S):
        name = plain(re.search(r"<h3>(.*?)</h3>", words, re.S).group(1))
        text = html.unescape(told) or " ".join(plain(p) for p in re.findall(r"<p>(.*?)</p>", words, re.S))
        found.append((name, text))
    return found


def schema(about, body, facts, changed):
    """What a page is, in the form search engines and AI assistants read (schema.org as JSON-LD).
    Set in the block at the top of a page:
      schema: app        the page presents the app itself (home, download)
      crumb: Name        the page's name in the trail "Phone Mirror > Name"
      howto: Title       the page's guide steps are the answer to this "how to"
    Questions and steps are read from the page's own words, so this never says more than the page.
    There is no price and there are no ratings in it, on purpose."""
    if "noindex" in about.get("robots", ""):
        return ""
    site, app, maker = SITE_URL + "/#website", SITE_URL + "/#app", SITE_URL + "/#maker"
    url = SITE_URL + about["path"]
    page = {"@type": "WebPage", "@id": url, "url": url, "name": about["title"],
            "description": about["description"], "inLanguage": "en", "dateModified": changed,
            "isPartOf": {"@id": site},
            "primaryImageOfPage": {"@type": "ImageObject", "url": SITE_URL + "/assets/og.png",
                                   "width": 1200, "height": 630}}
    graph = [
        {"@type": "WebSite", "@id": site, "url": SITE_URL + "/", "name": "Phone Mirror",
         "alternateName": ["PhoneMirror", "phonemirror.in"], "description": SUMMARY, "inLanguage": "en",
         "publisher": {"@id": maker}},
        {"@type": "Person", "@id": maker, "name": "Divas Sharma", "url": SITE_URL + "/"},
        page,
    ]

    if about.get("schema") == "app":
        page["about"] = {"@id": app}
        graph.append({
            "@type": "SoftwareApplication", "@id": app, "name": "Phone Mirror", "alternateName": "PhoneMirror",
            "description": SUMMARY, "url": SITE_URL + "/", "applicationCategory": "UtilitiesApplication",
            "operatingSystem": "macOS 14 or later", "processorRequirements": "Apple Silicon (M1 and newer)",
            "softwareRequirements": "An Android phone with Android 5 or newer",
            "softwareVersion": facts["version"], "fileSize": facts["size"],
            "downloadUrl": SITE_URL + DOWNLOAD, "installUrl": SITE_URL + "/download/",
            "softwareHelp": {"@type": "CreativeWork", "url": SITE_URL + "/setup/"},
            "featureList": FEATURES, "image": SITE_URL + "/assets/icon.png",
            "screenshot": [SITE_URL + "/assets/phone-files.png", SITE_URL + "/assets/quick-share.png",
                           SITE_URL + "/assets/getting-started.png"],
            "author": {"@id": maker}, "publisher": {"@id": maker}})

    asked = questions(body)
    if asked:
        page["@type"] = ["WebPage", "FAQPage"]
        page["mainEntity"] = [{"@type": "Question", "name": question,
                               "acceptedAnswer": {"@type": "Answer", "text": answer}}
                              for question, answer in asked]

    if about.get("howto"):
        graph.append({
            "@type": "HowTo", "@id": url + "#howto", "name": about["howto"], "inLanguage": "en",
            "mainEntityOfPage": {"@id": url},
            "step": [{"@type": "HowToStep", "position": number, "name": name, "text": text}
                     for number, (name, text) in enumerate(steps(body), 1)]})

    if about.get("crumb"):
        page["breadcrumb"] = {"@id": url + "#trail"}
        graph.append({
            "@type": "BreadcrumbList", "@id": url + "#trail",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Phone Mirror", "item": SITE_URL + "/"},
                {"@type": "ListItem", "position": 2, "name": about["crumb"], "item": url}]})

    data = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False,
                      separators=(",", ":"))
    return '<script type="application/ld+json">' + data.replace("</", "<\\/") + "</script>\n"


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
        # The day this page last changed: its own words, the frame around them, or the download it describes.
        changed = time.strftime("%Y-%m-%d", time.localtime(max(
            file.stat().st_mtime for file in (page, SITE / "layout.html", DMG))))
        header = re.match(r"\s*<!--(.*?)-->", text, re.S)
        if not header:
            sys.exit(f"{page.name} has no title/description/path block at the top")
        about = dict(line.split(":", 1) for line in header.group(1).strip().splitlines())
        about = {key.strip(): value.strip() for key, value in about.items()}
        body = fill(text[header.end():], facts)
        finished = fill(layout, {"robots": ROBOTS, **facts, **about, "head": head_extras(about),
                                 "schema": schema(about, body, facts, changed), "content": body})

        path = about["path"]
        target = OUT / (path.lstrip("/") + "index.html" if path.endswith("/") else path.lstrip("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(finished)
        if about.get("nav") != "none":
            paths.append((path, changed))

    # The download itself, and the small files search engines and hosts look for.
    (OUT / "download").mkdir(exist_ok=True)
    shutil.copy2(DMG, OUT / DOWNLOAD.lstrip("/"))
    (OUT / "download" / "SHA256SUMS.txt").write_text(f"{facts['sha256']}  Phone-Mirror.dmg\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}/sitemap.xml\n")
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"  <url><loc>{SITE_URL}{path}</loc><lastmod>{changed}</lastmod></url>\n"
                  for path, changed in sorted(paths)) + "</urlset>\n")
    # The site in plain words for AI assistants (the llms.txt convention).
    (OUT / "llms.txt").write_text(fill((SITE / "llms.txt").read_text(), facts))
    (OUT / ".nojekyll").write_text("")

    print(f"Built dist/site: version {facts['version']}, {facts['size']}, {len(paths)} pages")


if __name__ == "__main__":
    main()
