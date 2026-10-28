extends Node
## Dev-only visual check for the Area layout of the graph canvas: seeds a small
## scratch vault of subject-grouped notes, runs the body-word TF-IDF scan, and
## opens the real GraphView with the area layout active so the island
## clustering, labels and circle menu are visible.
##
## Run with a REAL renderer (headless renders nothing):
##   NEONNOTES_DEV=1 godot --path . scenes/dev/AreaBench.tscn
##
## Never touches the real vault or its settings; safe to delete.

const TfidfBodyStoreScript := preload("res://scripts/common/tfidf_body_store.gd")
const GraphViewScript := preload("res://scripts/render/graph_view.gd")
const PROBE_VAULT := "user://neonnotes-area-bench"

## Subject -> note bodies. Notes sharing a subject's vocabulary should cluster
## into one island; the four subjects stay apart.
const SUBJECTS := {
	"physics": [
		"energy quantum field particle",
		"energy entropy thermodynamics system",
		"energy relativity spacetime curvature",
	],
	"cooking": [
		"flavor pasta garlic sauce",
		"flavor bread sourdough yeast",
		"flavor tomato onion simmer",
	],
	"music": [
		"melody chord harmony progression",
		"melody counterpoint fugue voice",
		"melody rhythm tempo percussion",
	],
	"gardening": [
		"garden compost soil beds",
		"garden prune rose watering",
		"garden seed transplant seedling",
	],
}

func _ready() -> void:
	GameManager.suppress_settings_save = true
	RenderingServer.set_default_clear_color(Color(0.05, 0.06, 0.12, 1.0))

	var abs := ProjectSettings.globalize_path(PROBE_VAULT)
	if DirAccess.dir_exists_absolute(abs):
		DirAccess.remove_absolute(abs)
	DirAccess.make_dir_recursive_absolute(abs)
	for subject in SUBJECTS.keys():
		var bodies: Array = SUBJECTS[subject]
		for i in bodies.size():
			var f := FileAccess.open(PROBE_VAULT.path_join("%s_%d.md" % [subject, i]), FileAccess.WRITE)
			f.store_string(String(bodies[i]))
			f.close()

	GameManager.vault_dir = PROBE_VAULT
	GameManager.scan_paths()

	var store = TfidfBodyStoreScript.new()
	store.name = "TfidfBodyStore"
	add_child(store)
	var done := [false]
	store.index_ready.connect(func(): done[0] = true)
	store.rescan()
	var frames := 0
	while not done[0] and frames < 600:
		await get_tree().process_frame
		frames += 1

	var gv: GraphView = GraphViewScript.new()
	gv.name = "GraphAreaBench"
	gv.area_neighbours_cb = func(rel: String) -> Array:
		return store.top_neighbors(rel, 3)
	add_child(gv)
	gv.position = Vector2.ZERO
	gv.size = get_viewport().get_visible_rect().size
	gv.set_area_layout(true)
	gv.open("")
	await get_tree().process_frame
	await get_tree().process_frame
	print("[area bench] notes=%d keys=%d edge_pts=%d" % [
		GameManager.notes.size(), gv._keys.size(), gv._edge_pts.size() / 2])