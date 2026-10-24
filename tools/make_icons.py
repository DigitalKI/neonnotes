#!/usr/bin/env python3
"""Generate NeonNotes app icons from the master artwork.

The generated files under `assets/icons/` are committed, so an export does
not need Pillow. Re-run this only when `packaging/icons/neonnotes-master.jpg`
changes:

    python3 tools/make_icons.py

Outputs:
    assets/icons/neonnotes.png          canonical 512x512 app icon
    assets/icons/neonnotes-NN.png       hicolor sizes used by the Linux package
    assets/icons/neonnotes.ico          multi-size Windows icon
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
	from PIL import Image, ImageFilter
except ImportError:  # pragma: no cover - environment guard
	sys.exit("error: Pillow is required (python3 -m pip install --user Pillow)")

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "packaging" / "icons" / "neonnotes-master.jpg"
OUT = ROOT / "assets" / "icons"

PNG_SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
CANONICAL_SIZE = 512


def _square(master: Image.Image) -> Image.Image:
	if master.width == master.height:
		return master
	side = min(master.width, master.height)
	left = (master.width - side) // 2
	top = (master.height - side) // 2
	return master.crop((left, top, left + side, top + side))


def _render(master: Image.Image, size: int) -> Image.Image:
	img = master.resize((size, size), Image.LANCZOS)
	# Downscaling eats the thin neon strokes; a light unsharp pass keeps the
	# 16-32 px frames legible in file managers and taskbars.
	if size <= 48:
		img = img.filter(ImageFilter.UnsharpMask(radius=0.6, percent=45, threshold=2))
	return img


def main() -> int:
	if not MASTER.exists():
		sys.exit(f"error: master icon not found: {MASTER.relative_to(ROOT)}")

	master = _square(Image.open(MASTER).convert("RGB"))
	OUT.mkdir(parents=True, exist_ok=True)

	_render(master, CANONICAL_SIZE).save(OUT / "neonnotes.png", optimize=True)
	for size in PNG_SIZES:
		_render(master, size).save(OUT / f"neonnotes-{size}.png", optimize=True)

	_render(master, max(ICO_SIZES)).save(
		OUT / "neonnotes.ico",
		format="ICO",
		sizes=[(size, size) for size in ICO_SIZES],
	)

	print(f"wrote {len(PNG_SIZES) + 2} files to {OUT.relative_to(ROOT)}/")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
