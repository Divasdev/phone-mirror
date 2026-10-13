#!/usr/bin/env python3
"""Makes the small and modern copies of the website's pictures.

Run it after a picture in website/static/assets/ changes (a new screenshot, a new icon, a new
video poster). It needs Pillow (`pip install pillow`); build.py itself does not.

    python3 website/make_images.py

What it writes next to the originals:
  - icon-72.png, icon-208.png   the app icon at the sizes the pages show it (the original is 512 px)
  - <name>.webp                 a WebP copy of each screenshot and of the hero poster; the pages
                                offer it first and keep the PNG or JPEG for older browsers
"""

import pathlib

from PIL import Image

ASSETS = pathlib.Path(__file__).resolve().parent / "static" / "assets"

SCREENSHOTS = ["phone-files.png", "getting-started.png", "quick-share.png"]
POSTERS = ["video/hero-loop-poster.jpg"]
ICON_SIZES = [72, 208]


def kb(path):
    return f"{path.stat().st_size / 1024:.0f} KB"


def main():
    icon = Image.open(ASSETS / "icon.png").convert("RGBA")
    for size in ICON_SIZES:
        target = ASSETS / f"icon-{size}.png"
        icon.resize((size, size), Image.LANCZOS).save(target, optimize=True)
        print(f"{target.name}: {kb(target)}")

    for name in SCREENSHOTS:
        source = ASSETS / name
        if not source.exists():
            print(f"{name}: not there, skipped")
            continue
        target = source.with_suffix(".webp")
        # Lossless: screenshots are text and flat colour, which WebP keeps exactly and small.
        Image.open(source).save(target, "WEBP", lossless=True, quality=100, method=6)
        print(f"{target.name}: {kb(target)} (was {kb(source)})")

    for name in POSTERS:
        source = ASSETS / name
        target = source.with_suffix(".webp")
        Image.open(source).convert("RGB").save(target, "WEBP", quality=80, method=6)
        print(f"{target.name}: {kb(target)} (was {kb(source)})")


if __name__ == "__main__":
    main()
