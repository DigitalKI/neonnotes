extends Node
## Dev-only: scan the generated Godot-docs test vault through the real
## GameManager and assert the indexes the app relies on are healthy.
##
## The vault is built by `tools/gen_godot_docs_vault.py` (gitignored under
## build/). This harness only *reads* it — it never uses the real vault.
##
## Run (dev isolation is REQUIRED; the harness refuses a real session):
##   NEONNOTES_VAULT=$PWD/build/godot-docs-vault \
##     godot --headless --path . scenes/dev/VerifyDocsVault.tscn
##
## A different vault can be supplied with NEONNOTES_DOCS_VAULT.

const DEFAULT_VAULT := "res://build/godot-docs-vault"

## The generated vault is ~1080 class notes plus folder notes.
const MIN_NOTES := 1000
const REQUIRED_TAGS := [
	"godot", "api", "class", "popular", "has-methods", "has-properties",
	"2d", "3d", "ui", "node", "resource", "physics", "networking", "rendering",
]


func _ready() -> void:
	print("=== NeonNotes docs-vault verification ===")

	var path := OS.get_environment("NEONNOTES_DOCS_VAULT")
	if path == "":
		path = ProjectSettings.globalize_path(DEFAULT_VAULT)
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		_fail("vault not found: %s — run tools/gen_godot_docs_vault.py" % path)
		return
	if not GameManager.is_dev_session():
		_fail("refusing to run against the real vault — set NEONNOTES_VAULT=%s" % path)
		return

	# Assign the field directly (never set_vault_dir): settings must not persist.
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = path

	var t0 := Time.get_ticks_msec()
	GameManager.scan_notes()
	var scan_ms := Time.get_ticks_msec() - t0

	var errors: Array[String] = []
	var notes := GameManager.notes.size()
	var tagged := 0
	var link_count := 0
	for n in GameManager.notes:
		var tags: Array = GameManager.tags.get(n, [])
		if not tags.is_empty():
			tagged += 1
		link_count += GameManager.links.get(n, []).size()

	var all_tags := GameManager.all_tags()
	var graph := WikiLinks.graph()
	var graph_nodes: Array = graph["nodes"]
	var graph_links: Array = graph["links"]
	var tree_edges := 0
	for e in graph_links:
		if e["kind"] == "tree":
			tree_edges += 1

	print("notes=%d  scan=%dms  tagged=%d  distinct_tags=%d  links=%d"
		% [notes, scan_ms, tagged, all_tags.size(), link_count])
	print("graph: nodes=%d edges=%d (tree=%d, direct=%d)"
		% [graph_nodes.size(), graph_links.size(), tree_edges, graph_links.size() - tree_edges])
	print("tags: %s" % ", ".join(all_tags))

	if notes < MIN_NOTES:
		errors.append("expected >= %d notes, got %d" % [MIN_NOTES, notes])
	if tagged != notes:
		errors.append("%d notes carry no tag" % (notes - tagged))
	for t in REQUIRED_TAGS:
		if not all_tags.has(t):
			errors.append("missing expected tag: #%s" % t)
	if link_count < notes:
		errors.append("suspiciously few wiki-links: %d" % link_count)
	if graph_links.size() <= tree_edges:
		errors.append("no resolved cross-note links in the graph")

	# Known resolutions: base-class links and value-type links must land.
	var targets := {"Node": "nodes/Node.md", "Node2D": "2d/Node2D.md", "Sprite2D": "2d/Sprite2D.md",
		"Resource": "resources/Resource.md", "String": "built-in-types/String.md", "Object": "core/Object.md"}
	for name in targets:
		var got := WikiLinks.resolve(name)
		if got != targets[name]:
			errors.append("[[%s]] resolved to '%s', expected '%s'" % [name, got, targets[name]])

	if errors.is_empty():
		print("DOCS VAULT RESULT: OK")
	else:
		for e in errors:
			printerr("FAIL: " + e)
		print("DOCS VAULT RESULT: FAILED (%d)" % errors.size())
	get_tree().quit()


func _fail(message: String) -> void:
	printerr("FAIL: " + message)
	print("DOCS VAULT RESULT: FAILED (1)")
	get_tree().quit()
