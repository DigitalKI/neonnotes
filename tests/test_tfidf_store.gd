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

	# The vault holds the three subject notes plus the auto-created Inbox
	# companion (the Inbox is a plain vault folder, ADR-0009), so every stat
	# below counts it too.
	var ncount := GameManager.notes.size()
	var s1: Dictionary = store.last_scan
	check.call("a cold scan reads and tokenises every note",
		int(s1.get("read", -1)) == ncount
		and int(s1.get("tokenized", -1)) == ncount
		and int(s1.get("cached", -1)) == 0)

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

	# The save also re-embeds on the worker (ADR-0016): positions arrive async
	# through positions_ready and cover the vault. Awaited before freeing the
	# store so no deferred emission lands on a freed object.
	var embedded := [false]
	store.positions_ready.connect(func(): embedded[0] = true)
	var eframes := 0
	while not embedded[0] and eframes < 600:
		await get_tree().process_frame
		eframes += 1
	check.call("invalidate re-embeds on the worker", embedded[0])
	check.call("the embedding covers every note",
		store.area_positions().size() == GameManager.notes.size())

	# The sidecar cache (ADR-0016 Phase 3): a restart-shaped rescan serves
	# every unchanged note from the cache without a read, and reuses the
	# identical positions when the corpus fingerprint has not moved.
	var cp := store.cache_path()
	check.call("the sidecar cache exists after a scan", FileAccess.file_exists(cp))
	var first_pos: Dictionary = store.area_positions().duplicate(true)
	var store2 = TfidfBodyStoreScript.new()
	store2.name = "TfidfBodyStore2"
	add_child(store2)
	var ready2 := [false]
	store2.index_ready.connect(func(): ready2[0] = true)
	store2.rescan()
	var frames2 := 0
	while not ready2[0] and frames2 < 600:
		await get_tree().process_frame
		frames2 += 1
	check.call("a warm boot finishes from the cache", ready2[0])
	var s2: Dictionary = store2.last_scan
	check.call("unchanged notes load from the cache without a read",
		int(s2.get("cached", -1)) == ncount and int(s2.get("read", -1)) == 0
		and int(s2.get("tokenized", -1)) == 0)
	check.call("an unchanged corpus reuses the cached positions verbatim",
		store2.area_positions() == first_pos)

	# A changed note is backfilled: re-read, re-tokenised, warm re-embed. The
	# wait crosses the mtime second boundary so the change is visible to the
	# stat check.
	await get_tree().create_timer(1.2).timeout
	_write(PROBE_VAULT.path_join("physics.md"),
		"Cooking pasta with garlic and olive oil again")
	ready2[0] = false
	store2.rescan()
	frames2 = 0
	while not ready2[0] and frames2 < 600:
		await get_tree().process_frame
		frames2 += 1
	var s3: Dictionary = store2.last_scan
	check.call("a changed note is re-read and re-tokenised",
		int(s3.get("cached", -1)) == ncount - 1 and int(s3.get("read", -1)) == 1
		and int(s3.get("tokenized", -1)) == 1)
	check.call("a changed corpus re-embeds from the warm cache",
		not (store2.area_positions() == first_pos))

	# A corrupt cache file self-heals: the scan falls back to a full read.
	var cf := FileAccess.open(cp, FileAccess.WRITE)
	cf.store_string("not json at all")
	cf.close()
	ready2[0] = false
	store2.rescan()
	frames2 = 0
	while not ready2[0] and frames2 < 600:
		await get_tree().process_frame
		frames2 += 1
	var s4: Dictionary = store2.last_scan
	check.call("a corrupt cache falls back to a full scan",
		int(s4.get("read", -1)) == ncount
		and int(s4.get("tokenized", -1)) == ncount
		and store2.area_positions().size() == ncount)

	store.queue_free()
	store2.queue_free()
	await get_tree().process_frame

	DirAccess.remove_absolute(ProjectSettings.globalize_path(cp))
	DirAccess.remove_absolute(abs)
	GameManager.vault_dir = GameManager.VAULT_DIR
	print("TFIDF RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)

func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
