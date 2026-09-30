extends Node
## Dev-only: time PreviewBuilder.build() on a real note and count the nodes it
## produces.  Run as a scene so autoloads exist:
##   godot --headless --path . scenes/dev/BenchPreview.tscn
## Optional: NEONNOTES_BENCH_NOTE=user://vault/path.md (defaults to the brief).

const ParserScript := preload("res://scripts/markdown/markdown_parser.gd")

func _ready() -> void:
	var path := OS.get_environment("NEONNOTES_BENCH_NOTE")
	if path == "":
		path = "user://vault/Gamedev/Next Steps & Implementation Plan.md"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("BENCH-PREVIEW could not open ", path)
		get_tree().quit()
		return
	var text := f.get_as_text()
	f.close()

	var t0 := Time.get_ticks_msec()
	var doc: Dictionary = ParserScript.parse(text)
	var parse_ms := Time.get_ticks_msec() - t0
	var blocks: Array = doc.get("blocks", [])
	var kinds := {}
	for b in blocks:
		kinds[b["type"]] = int(kinds.get(b["type"], 0)) + 1

	var holder := VBoxContainer.new()
	holder.size = Vector2(800, 4000)
	add_child(holder)

	t0 = Time.get_ticks_msec()
	PreviewBuilder.build(doc, holder)
	var build_ms := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	PreviewBuilder.build(doc, holder)
	var warm_ms := Time.get_ticks_msec() - t0
	print("BENCH-PREVIEW lines=%d blocks=%d parse=%dms build=%dms warm=%dms nodes=%d kinds=%s"
		% [text.split("\n").size(), blocks.size(), parse_ms, build_ms, warm_ms, _count(holder), str(kinds)])
	get_tree().quit()


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
