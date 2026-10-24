#!/usr/bin/env python3
"""Derive the per-platform still sizes social networks ask for.

  python3 tools/social/platform_sizes.py [captures_dir]

Reads the 16:9 hero shot written by tools/social/CaptureStage.tscn and writes
exact-size copies into <captures_dir>/platform/. Pure resampling — no padding or
cropping, so nothing the UI shows gets cut off.
"""
import os
import sys

from PIL import Image

# platform file -> (width, height, note)
TARGETS = {
    "x-post.png": (1600, 900, "X / Twitter in-stream image"),
    "bluesky.png": (1600, 900, "Bluesky (2000x2000 max, 16:9 reads well)"),
    "mastodon.png": (1600, 900, "Mastodon card"),
    "linkedin.png": (1200, 627, "LinkedIn link preview"),
    "og-image.png": (1200, 630, "OpenGraph / GitHub social preview"),
    "producthunt-gallery.png": (1270, 760, "Product Hunt gallery"),
}


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.join("marketing", "captures")
    hero = os.path.join(base, "01-hero-preview.png")
    if not os.path.exists(hero):
        sys.exit(f"missing {hero} — run tools/social/CaptureStage.tscn first")
    out_dir = os.path.join(base, "platform")
    os.makedirs(out_dir, exist_ok=True)
    src = Image.open(hero).convert("RGB")
    for name, (w, h, note) in TARGETS.items():
        img = src.resize((w, h), Image.LANCZOS)
        path = os.path.join(out_dir, name)
        img.save(path, optimize=True)
        print(f"{path}  {w}x{h}  {os.path.getsize(path) / 1024:.0f} KB  {note}")


if __name__ == "__main__":
    main()
