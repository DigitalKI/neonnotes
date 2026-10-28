class_name GraphColors
extends RefCounted
## Shared, pure graph colour helpers so the radial GraphView and the Area View
## derive a note's colour from the same rule — a note keeps its colour when you
## switch views, and across synced devices. A note's colour is a function of
## its top-level folder: every folder hashes to its own hue on a generated
## OKHSL wheel, so the palette has no fixed size and folders never need to
## share a colour (ADR-0017). Folder-less root notes fall back to the theme's
## accent2.

## Where every folder hue lives: constant OKHSL saturation and lightness.
## OKHSL is perceptually uniform, so all folder colours read equally bright —
## only the hue differs, which is what keeps a dense map legible. Tuned to the
## neon family of the old fixed palette on the dark themes (no folder pops
## harder or fades into the background).
const SATURATION := 0.85
const LIGHTNESS := 0.80

## Minimum circular distance between two folder hues (22.5°). Up to ~8
## top-level folders every pair stays at least this far apart, so hues are
## clearly distinct; past that budget the walk is best-effort and new folders
## close in on the widest gaps left.
const HUE_MIN_GAP := 1.0 / 16.0

## The golden-angle rotation. When a folder's hash hue lands too close to an
## already-placed one, stepping by this fraction hops to the farthest free
## hue first — the classic maximally-spread sequence behind categorical
## colour generators.
const GOLDEN_STEP := 0.6180339887498949

## {folder: Color} for every top-level folder in `notes`; the views build it
## once per vault rebuild and share it, so a note keeps its colour across the
## radial ⇄ area switch. Deterministic: folders are placed in sorted name
## order, each at its hash hue, and only a folder that collides with an
## already-placed hue is pushed to the next free hue — so colours are stable
## across launches, devices and vault edits (a folder only moves when a new
## neighbour actually collides with it).
static func build_palette(notes: Array) -> Dictionary:
	var folders: Array[String] = []
	var seen := {}
	for note in notes:
		var rel := String(note)
		var slash := rel.find("/")
		if slash <= 0:
			continue  # root note: it has no top-level folder
		var folder := rel.substr(0, slash)
		if not seen.has(folder):
			seen[folder] = true
			folders.append(folder)
	folders.sort()  # deterministic placement order (ties resolve by name)
	var palette := {}
	var hues: Array = []
	for folder in folders:
		var hue := _hash_hue(folder)
		# Repair pass: step the golden angle until far enough from every
		# placed hue, remembering the widest-gap candidate so the walk always
		# terminates (deterministically) even past the hue budget.
		var best := hue
		var best_gap := _hue_gap(hue, hues)
		var candidate := hue
		for i in hues.size() + 2:
			if best_gap >= HUE_MIN_GAP:
				break
			candidate = fposmod(candidate + GOLDEN_STEP, 1.0)
			var gap := _hue_gap(candidate, hues)
			if gap > best_gap:
				best_gap = gap
				best = candidate
		hues.append(best)
		palette[folder] = Color.from_ok_hsl(best, SATURATION, LIGHTNESS)
	return palette

## Colour for a vault-relative note path inside a built palette: the
## top-level folder's colour, or `accent2` for root notes (and any folder a
## stale palette has not mapped).
static func section_color(path: String, palette: Dictionary, accent2: Color) -> Color:
	var parts := path.split("/")
	if parts.size() > 1 and palette.has(parts[0]):
		return palette[parts[0]]
	return accent2

## Fold a folder name onto the hue wheel. String.hash()'s low bits cluster on
## short names ("work", "code" and "papa" all land within 0.0005 of each other
## without this), so diffuse with the murmur3 32-bit finalizer before reading
## the hash as a hue. Underscored but stable: the unit tests assert the
## collision-repair behaviour through it.
static func _hash_hue(folder: String) -> float:
	var h := folder.hash() & 0xffffffff
	h ^= h >> 16
	h = (h * 0x85ebca6b) & 0xffffffff
	h ^= h >> 13
	h = (h * 0xc2b2ae35) & 0xffffffff
	h ^= h >> 16
	return float(h) / 4294967296.0

## Circular distance from `hue` to the closest hue in `placed` (1.0 when empty).
static func _hue_gap(hue: float, placed: Array) -> float:
	var gap := 1.0
	for other in placed:
		var d := absf(hue - float(other))
		gap = minf(gap, minf(d, 1.0 - d))
	return gap