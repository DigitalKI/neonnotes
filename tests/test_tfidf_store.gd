extends Node
## Headless check for the Area View body-word TF-IDF background scan: the store
## builds an index over a scratch vault on a worker, then answers top-k
## neighbours; invalidate re-indexes a changed note. Disposable vault, assigned
## directly (never set_vault_dir(), which would persist vault.dir).

const TfidfBodyStoreScript := preload("res://scripts/common/tfidf_body_store.gd")
const PROBE_VAULT := "user://neonnotes-tfidf-probe"

var _fails := 0

func _ready() -> void:
	var check := func(name: String, ok: bool) -> void:
		print(("  ok  " if ok else "  FAIL ") + name)
		if not ok:
			_fails += 1

	var abs := ProjectSettings.globalize_path(PROBE_VAULT)
	DirAccess.make_dir_recursive_absolute(abs)
	_write(PROBE_VAULT.path_join("physics.md"), "Quantum physics and the second law of thermodynamics")
	_write(PROBE_VAULT.path_join("space.md"), "Relativity black holes and the second law")
	_write(PROBE_VAULT.path_join("cooking.md"), "Pasta recipes with garlic and olive oil")

	GameManager.vault_dir = PROBE_VAULT
	GameManager.scan_paths()

	var store = TfidfBodyStoreScript.new()
	store.name = "TfidfBodyStore"
	add_child(store)
	var ready := [false]
	store.index_ready.connect(func(): ready[0] = true)
	store.rescan()
	var frames := 0
	while not ready[0] and frames < 600:
		await get_tree().process_frame
		frames += 1
	check.call("store finishes the background scan", ready[0])

	var top = store.top_neighbors("physics.md", 1)
	check.call("store returns top-k neighbours", top.size() == 1)
	if top.size() > 0:
		check.call("the shared-subject note is nearest", String(top[0]["note"]) == "space.md")

	# Change physics.md's subject and confirm invalidate re-reads and re-ranks.
	_write(PROBE_VAULT.path_join("physics.md"), "Pasta and olive oil and garlic recipes")
	store.invalidate("physics.md")
	top = store.top_neighbors("physics.md", 1)
	if top.size() > 0:
		check.call("invalidate re-indexes the changed note", String(top[0]["note"]) == "cooking.md")

	store.queue_free()
	await get_tree().process_frame

	DirAccess.remove_absolute(abs)
	GameManager.vault_dir = GameManager.VAULT_DIR
	print("TFIDF RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
