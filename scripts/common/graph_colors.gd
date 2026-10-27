class_name GraphColors
extends RefCounted
## Shared, pure graph colour helpers so the radial GraphView and the Area View
## derive a note's colour from the same rule — a note keeps its colour when you
## switch views. A note's colour is a function of its top-level folder (hashed
## into a fixed palette); folder-less root notes fall back to the theme's
## accent2.

## The fixed folder palette (synthwave): one bucket per top-level folder.
const FOLDER_PALETTE := [
	Color("#ff4fd8"), Color("#45e6ff"), Color("#ffb347"),
	Color("#a78bfa"), Color("#7dff8a"), Color("#ff6b6b"),
]

## Colour for a vault-relative note path: hash the top-level folder into the
## palette; root notes (no folder) fall back to `accent2`.
static func section_color(path: String, accent2: Color) -> Color:
	var parts := path.split("/")
	if parts.size() > 1:
		var index := int(parts[0].hash() & 0x7fffffff) % FOLDER_PALETTE.size()
		return FOLDER_PALETTE[index]
	return accent2
