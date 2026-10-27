extends SceneTree
## Dev-only benchmark: how does RelationshipEngine.infer() scale with note count
## now that it uses inverted-index candidate generation instead of all-pairs?
##
## Run headless:  godot --headless --path . --script scripts/dev/bench_infer.gd
##
## Pure and side-effect free: it builds synthetic notes/tags/links/titles in
## memory with *bounded* bucket sizes (folders/tags/words grow in number with n),
## so co-occurrence stays linear and the sweep shows sub-quadratic scaling.
## Never touches the vault or settings.

const COUNTS := [1000, 2000, 5000, 10000]
const RelationshipEngineScript := preload("res://scripts/common/relationship_engine.gd")

func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for n in COUNTS:
		var d := _make_data(n, rng)
		var t0 := Time.get_ticks_usec()
		var rels := RelationshipEngineScript.infer(d["notes"], d["links"], d["tags"], d["titles"])
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		print("BENCH infer notes=%d rels=%d time=%.1fms" % [n, rels.size(), ms])
	quit()

## Diverse synthetic vault: ~8 notes/folder, ~20 notes/tag, ~24 notes/word, so
## each inverted-index bucket stays small and total co-occurrence is O(n).
func _make_data(n: int, rng: RandomNumberGenerator) -> Dictionary:
	var notes: Array[String] = []
	var tags := {}
	var links := {}
	var titles := {}
	var n_tags := maxi(1, n / 20)
	var n_words := maxi(1, n / 8)
	for i in n:
		var folder := "F%05d" % (i / 8)
		var path := "%s/Note%06d.md" % [folder, i]
		notes.append(path)
		var ts := []
		for j in 1 + rng.randi_range(0, 1):
			ts.append("tag%d" % rng.randi_range(0, n_tags - 1))
		tags[path] = ts
		var ws := []
		for j in 3:
			ws.append("word%d" % rng.randi_range(0, n_words - 1))
		titles[path] = " ".join(ws)
		if i > 0 and rng.randi_range(0, 1) == 0:
			links[path] = ["Note%06d" % rng.randi_range(0, n - 1)]
	return {"notes": notes, "tags": tags, "links": links, "titles": titles}
