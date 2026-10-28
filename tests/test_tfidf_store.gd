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
	# The store debounces re-embeds and throttles sidecar persists (INV-015:
	# the save path never joins a worker). Shrink both knobs so the awaited
	# transitions stay fast and deterministic here; store2 below keeps the
	# shipping throttle to check it.
	store.embed_debounce_s = 0.05
	store.persist_interval_ms = 0
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
	# Fast debounce for the awaited transitions; the persist throttle keeps its
	# shipping default here so the burst checks below observe it.
	store2.embed_debounce_s = 0.05
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

	# Tags fold into the semantic signal (boosted bag terms): two notes with
	# disjoint vocabularies but a shared tag become each other's nearest
	# neighbour — the bridging property that matters in a multilingual vault,
	# where a shared tag reads the same in any language.
	_write(PROBE_VAULT.path_join("bake.md"),
		"---\ntitle: Baking\ntags: trip\n---\n\nSourdough bread and yeast.")
	_write(PROBE_VAULT.path_join("song.md"),
		"---\ntitle: Chords\ntags: trip\n---\n\nMelody and harmony.")
	GameManager.scan_paths()
	ready2[0] = false
	store2.rescan()
	frames2 = 0
	while not ready2[0] and frames2 < 600:
		await get_tree().process_frame
		frames2 += 1
	var top_trip := store2.top_neighbors("bake.md", 1)
	check.call("a shared tag connects disjoint vocabularies",
		top_trip.size() == 1 and String(top_trip[0]["note"]) == "song.md")
	var top_back := store2.top_neighbors("song.md", 1)
	check.call("the tag bridge is symmetric",
		top_back.size() == 1 and String(top_back[0]["note"]) == "bake.md")

	# The parse half of the tag fold lives here (not in unit_tests.gd): the
	# store class references the GameManager autoload, which a --script
	# (MainLoop) run cannot compile, so unit_tests must stay store-free.
	check.call("tag terms parse from a front-matter value",
		TfidfBodyStoreScript._tag_terms("alpha, beta, #gamma")
		== ["alpha", "beta", "gamma"])
	check.call("empty tags fold in nothing",
		TfidfBodyStoreScript._tag_terms("   ") == [])

	# --- the save-path regression (INV-015): debounced, coalesced, never joined
	# A typing burst is three saves in one frame (the autosave debounce fires
	# per save). They must coalesce into ONE re-embed — the pre-fix code joined
	# a whole-vault embed per save, which froze typing on phones (GOT-027).
	# The counter is an array because lambdas capture locals by value.
	var embeds := [0]
	store2.positions_ready.connect(func(): embeds[0] += 1)
	var cache_before := _read_text(cp)
	store2.invalidate("bake.md")
	store2.invalidate("song.md")
	store2.invalidate("bake.md")
	# Headless frames pump far faster than real time, so wait on the clock,
	# not on a frame count — the debounce timer needs real engine time to fire.
	var deadline := Time.get_ticks_msec() + 3000
	while embeds[0] < 1 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check.call("a typing burst coalesces into one re-embed", embeds[0] == 1)
	# The burst embed ran within the persist throttle window of the last scan
	# write, so the multi-megabyte sidecar dump must have been skipped.
	check.call("a throttled re-embed skips the sidecar persist",
		_read_text(cp) == cache_before)

	# Past the interval the embed persists again. Even a note whose content
	# did not change re-indexes (invalidate never stat-compares), so the doc
	# moves — and the throttle no longer suppresses it.
	store2.persist_interval_ms = 0
	store2.invalidate("song.md")
	deadline = Time.get_ticks_msec() + 3000
	while embeds[0] < 2 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check.call("a re-embed past the interval persists the cache",
		_read_text(cp) != cache_before)

	# While a worker is in flight, invalidate queues instead of mutating or
	# joining, and the worker's deferred completion drains the queue. Real
	# worker timing is not deterministic in a headless run, so the busy flag
	# and the completion entry point are driven directly — the same paths the
	# workers take.
	_write(PROBE_VAULT.path_join("song.md"), "Melody and harmony without tags")
	store2._scan_busy = true
	store2.invalidate("song.md")
	check.call("a busy worker queues the invalidation",
		store2._pending.has("song.md"))
	var stale_top := store2.top_neighbors("song.md", 1)
	check.call("the queued rel is not indexed yet",
		stale_top.size() == 1 and String(stale_top[0]["note"]) == "bake.md")
	store2._scan_busy = false
	store2._emit_ready(store2._generation)
	check.call("the worker's completion drains the queue",
		not store2._pending.has("song.md"))
	var top_dropped := store2.top_neighbors("song.md", 1)
	check.call("the drained re-index takes effect",
		top_dropped.size() == 0 or String(top_dropped[0]["note"]) != "bake.md")

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


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t
