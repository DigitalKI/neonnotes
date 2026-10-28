class_name TfidfBodyStore
extends Node
## Worker + cache behind the Area View semantic index (ADR-0013 / ADR-0016).
##
## Builds a body-word TF-IDF index over the whole vault on a worker thread, so
## the one-time scan never blocks the boot (INV-015), and embeds the k-NN
## similarity graph into Area View positions in the same pass. The scan is
## cache-aware: token counts, positions and per-note provenance (mtime + a
## content hash) persist in a sidecar JSON under user:// — never inside the
## vault, whose notes stay the only source of truth. A warm boot stats every
## note: unchanged notes load their cached counts without a read, only new
## or touched notes are read and (when their content moved) tokenised — the
## backfill — and when the whole corpus fingerprint is unchanged the cached
## embedding is reused verbatim; otherwise the embedding is warm-started from
## the cached positions so an edit shifts only its own neighbourhood.
##
## The save path never joins a worker (INV-015): a whole-vault embed is ~1 s
## on a desktop CPU and multi-second on a phone, so joining it per autosave
## froze typing and tripped Android's ANR. `invalidate()` instead re-indexes
## the one note synchronously (a single tokenize pass, ~ms) so the focus card
## stays fresh, debounces the re-embed (one embed per typing burst, not one
## per save), and — while a worker is in flight — queues the rel for the
## worker's own deferred completion to drain. The sidecar persist rides the
## same discipline: the boot scan always persists, but re-embeds persist at
## most once per `persist_interval_ms`, because stringifying the whole corpus
## is a multi-megabyte allocation a phone cannot pay per keystroke pause. A
## skipped persist loses nothing: the next boot's stat-and-hash backfill
## re-reads exactly the notes that changed.

signal index_ready
signal positions_ready

const TfidfIndexScript := preload("res://scripts/common/tfidf_index.gd")
const AreaEmbeddingScript := preload("res://scripts/common/area_embedding.gd")

## Cache format version; a mismatch (or corrupt JSON) drops the file and falls
## back to one full scan, so the cache is always an accelerator, never a
## requirement. Bump it whenever the bag semantics change — v2: tags fold into
## the bag, so a v1 cache would otherwise keep serving pre-tag bags for every
## mtime-unchanged note.
const CACHE_VERSION := 2
const VAULT_ID_FILE := ".neonnotes-id"

## Debounce between the last save invalidation and the re-embed (seconds).
## Long enough that a typing burst coalesces into one embed, short enough
## that the map follows an edit without a visible lag.
const EMBED_DEBOUNCE_S := 1.5
## Minimum gap between sidecar persists from re-embeds (ms). The boot scan
## always persists; between re-embeds the dump is throttled to this rate
## because the JSON is whole-corpus sized (megabytes on a real vault).
const PERSIST_INTERVAL_MS := 10000

## k for the neighbour graph the embedding consumes; the shell owns the knob.
var embed_k := 3
## Test/bench knobs; the defaults above are the shipping behaviour.
var embed_debounce_s := EMBED_DEBOUNCE_S
var persist_interval_ms := PERSIST_INTERVAL_MS

var _index = TfidfIndexScript.new()
var _positions := {}
var _cache_doc := {}    # the whole sidecar document (version/fingerprint/positions/notes)
var _vault := ""
var _generation := 0
var _mutex := Mutex.new()
var _thread: Thread
var _embed_thread: Thread
## True while a worker whose deferred completion has not run yet is current
## (generation matches). Main-thread only: set when a worker starts, cleared
## by the worker's deferred completion or by whoever joins the worker. A
## superseded worker's deferred skips the flag — a newer worker owns it.
var _scan_busy := false
var _embed_busy := false
## rel -> true; invalidations queued while a worker is busy. Drained on the
## main thread by the busy worker's deferred completion, which then reschedules
## the debounced re-embed.
var _pending := {}
var _last_persist_ms := 0
var _exiting := false
var _debounce: Timer
## Provenance of the last scan — {notes, cached, read, tokenized,
## reused_positions} — published under the same mutex as the results; tests
## and the bench read it. Empty until the first scan completes.
var last_scan := {}

func _ready() -> void:
	_debounce = Timer.new()
	_debounce.name = "EmbedDebounce"
	_debounce.one_shot = true
	_debounce.timeout.connect(_on_embed_debounce)
	add_child(_debounce)

func _exit_tree() -> void:
	# Teardown joins like every store here (GraphDigestStore does the same);
	# outside teardown the save path never joins (see invalidate). Both joins
	# are bounded to a single pass each: the debounce + busy-queue design
	# keeps at most one scan and one embed in flight, and neither starts
	# while `_exiting` is set.
	_exiting = true
	if _debounce != null:
		_debounce.stop()
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

## Start a full-vault scan on the worker. Call once the vault's note list is
## final (after metadata_ready); a repeat call replaces any in-flight scan.
## The worker backfills from the sidecar cache, embeds (warm-started when the
## corpus changed, reused verbatim when it did not), delivers both, then
## re-persists the cache — nothing touches the main thread. Joins whatever is
## in flight first: this is the boot / vault-switch path, not the typing path.
func rescan() -> void:
	_generation += 1
	_vault = GameManager.vault_abs()
	var gen := _generation
	var vault := _vault
	var names: Array[String] = GameManager.notes.duplicate()
	var k := embed_k
	var cache_path := _cache_path_for(vault)
	# The scan re-reads every note from disk, so queued edits ride along in
	# the files; nothing else may schedule an embed against the old state.
	_pending.clear()
	if _debounce != null:
		_debounce.stop()
	_join_embed()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	# The joined scan's deferred completion is stale now (the generation moved)
	# and skips itself, so the busy flag simply transfers to the new scan.
	_last_persist_ms = Time.get_ticks_msec()   # the boot scan always persists
	_scan_busy = true
	_thread = Thread.new()
	_thread.start(_scan_worker.bind(gen, vault, names, k, cache_path))

## The sidecar cache path for the current vault (tests clean it up).
func cache_path() -> String:
	return _cache_path_for(_vault if _vault != "" else GameManager.vault_abs())

## The whole-vault Area View embedding ({note: Vector2} in map space, from
## `AreaEmbedding`); empty until the scan has delivered. The view falls back
## to the island-grid layout while it is empty (ADR-0016). The reference is
## taken under the mutex because a worker swaps it; the object itself is
## never mutated after publish, so the caller may read it without the lock.
func area_positions() -> Dictionary:
	_mutex.lock()
	var pos := _positions
	_mutex.unlock()
	return pos

## Top-k TF-IDF neighbours for a note; empty until the scan has indexed it.
func top_neighbors(rel: String, k: int) -> Array:
	_mutex.lock()
	var idx = _index
	_mutex.unlock()
	return idx.top_neighbors(rel, k)

## Re-index one note after its text changed (editor save path). The re-index
## itself is synchronous (~ms) so `top_neighbors` answers the new text right
## away; the re-embed is debounced. While a worker is in flight the rel is
## queued instead — the worker's deferred completion drains the queue and
## reschedules — so the save path never blocks on `wait_to_finish()` and
## never mutates state a worker still reads (INV-015).
func invalidate(rel: String) -> void:
	if _exiting:
		return
	if _scan_busy or _embed_busy:
		_pending[rel] = true
		return
	_apply_invalidate(rel)
	_schedule_embed()

## Read + re-tokenise one note into the index and the cache document.
## Main thread only, and only when both workers are idle — the callers
## (`invalidate`, `_drain_pending`) gate that.
func _apply_invalidate(rel: String) -> void:
	var abs := _vault.path_join(rel)
	var text := TextIO.read_text(abs)
	var bag := _bag(text)
	_index.index_note(rel, bag)
	var key := String(rel)
	if typeof(_cache_doc.get("notes")) != TYPE_DICTIONARY:
		_cache_doc["notes"] = {}
	_cache_doc["notes"][key] = {"m": int(FileAccess.get_modified_time(abs)),
		"h": bag.hash(), "tf": _index.term_counts(key)}

## (Re)start the debounce; every invalidation restarts it, so a typing burst
## coalesces into exactly one embed once the burst settles.
func _schedule_embed() -> void:
	if _debounce == null or _exiting:
		return
	_debounce.wait_time = maxf(0.05, embed_debounce_s)
	_debounce.start()

func _on_embed_debounce() -> void:
	if _exiting or _scan_busy or _embed_busy:
		return   # a worker is finishing; its completion drains + reschedules
	_start_reembed()

## Drop the index, embedding and cache document on vault switch / import /
## restore. The sidecar file itself stays (keyed per vault) and is simply
## reloaded by the next rescan of the same vault. Joins the in-flight embed
## (vault-switch path, bounded to one pass) and bumps the generation so the
## stale completions of either worker cannot resurrect the cleared state.
func clear() -> void:
	_generation += 1
	_join_embed()
	_index = TfidfIndexScript.new()
	_positions = {}
	_cache_doc = {}
	_pending.clear()
	if _debounce != null:
		_debounce.stop()   # a pending timer would embed (and persist) the
		                   # cleared state against the next vault's cache path
	_vault = GameManager.vault_abs()

# ------------------------------------------------------------------ workers

## The backfill scan: stat every note, take unchanged ones from the cache,
## read (and only re-tokenise when their hash moved) the rest, rebuild the
## index from the counts, then embed — verbatim reuse when the corpus
## fingerprint matches the cache, warm-start otherwise.
func _scan_worker(gen: int, vault: String, names: Array[String], k: int,
		cache_path: String) -> void:
	var raw = TextIO.read_json(cache_path)
	var cache: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	if int(cache.get("version", 0)) != CACHE_VERSION \
			or typeof(cache.get("notes")) != TYPE_DICTIONARY:
		cache = {}
	var cached_notes: Dictionary = cache.get("notes", {})
	var stats := {"notes": names.size(), "cached": 0, "read": 0,
		"tokenized": 0, "reused_positions": false}
	var counts := {}
	var notes_out := {}
	for rel in names:
		var key := String(rel)
		var abs := vault.path_join(key)
		var entry: Dictionary = cached_notes.get(key, {})
		var mtime := int(FileAccess.get_modified_time(abs))
		if not entry.is_empty() and int(entry.get("m", -1)) == mtime:
			# unchanged on disk: the cached counts serve, no read at all
			var tf: Dictionary = entry.get("tf", {})
			counts[key] = tf
			notes_out[key] = {"m": mtime, "h": int(entry.get("h", 0)), "tf": tf}
			stats["cached"] = int(stats["cached"]) + 1
			continue
		# new or touched: read it, then tokenise only when the content hash
		# moved (a pure touch keeps the cached counts)
		var bag := _bag(TextIO.read_text(abs))
		var h := bag.hash()
		stats["read"] = int(stats["read"]) + 1
		if not entry.is_empty() and int(entry.get("h", -2)) == h:
			var tf_kept: Dictionary = entry.get("tf", {})
			counts[key] = tf_kept
			notes_out[key] = {"m": mtime, "h": h, "tf": tf_kept}
			continue
		var tf_new: Dictionary = TfidfIndexScript.tokenize(bag)
		stats["tokenized"] = int(stats["tokenized"]) + 1
		counts[key] = tf_new
		notes_out[key] = {"m": mtime, "h": h, "tf": tf_new}
	var idx = TfidfIndexScript.new()
	idx.build_counts(counts)
	var fingerprint := _fingerprint(notes_out)
	var embed := {}
	if fingerprint == int(cache.get("fingerprint", -1)) \
			and typeof(cache.get("positions")) == TYPE_DICTIONARY:
		embed = _positions_from_cache(cache["positions"], notes_out)
		stats["reused_positions"] = true
	else:
		var warm := _positions_from_cache(cache.get("positions", {}), notes_out)
		embed = AreaEmbeddingScript.layout(idx.knn_graph(k),
			AreaEmbeddingScript.ITERATIONS, warm)
	var doc := {"version": CACHE_VERSION, "fingerprint": fingerprint,
		"positions": _positions_to_cache(embed), "notes": notes_out}
	_mutex.lock()
	if gen == _generation:
		_index = idx
		_positions = embed
		_cache_doc = doc
		last_scan = stats
	_mutex.unlock()
	_save_cache(cache_path, doc)
	call_deferred("_emit_ready", gen)

func _emit_ready(gen: int) -> void:
	if _exiting or gen != _generation:
		return   # a newer rescan owns the state *and* the busy flag; its own
		        # completion clears it. Clearing here would let an invalidate
		        # mutate the index while that newer scan still runs.
	_scan_busy = false
	if is_inside_tree():
		index_ready.emit()
		positions_ready.emit()
	_drain_pending()

## Start the re-embed worker, warm-started from the current positions. Only
## the debounce timer starts it, so at most one embed runs at a time and the
## main thread never joins it. `persist` is pre-decided on the main thread
## (throttled against the last persist); a skipped persist loses nothing —
## the next boot's stat-and-hash backfill re-reads the changed notes.
func _start_reembed() -> void:
	var gen := _generation
	var k := embed_k
	var cache_path := _cache_path_for(_vault)
	var persist := Time.get_ticks_msec() - _last_persist_ms >= persist_interval_ms
	if persist:
		_last_persist_ms = Time.get_ticks_msec()
	# Realize the previous thread object: the busy gate plus the completion
	# deferred mean its callable has already returned, so this is bookkeeping
	# Godot requires before the object is replaced — it never waits on work.
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()
	_mutex.lock()
	var idx = _index      # quiescent: the busy gates + drains serialize this
	var notes = _cache_doc.get("notes", {})
	var warm = _positions
	_mutex.unlock()
	_embed_busy = true
	_embed_thread = Thread.new()
	_embed_thread.start(_embed_worker.bind(gen, k, cache_path, idx, notes, warm, persist))

## Re-embed the captured index on the worker, warm-started from the captured
## positions, and persist the cache when the throttle allows. Everything the
## worker touches was captured at start; nothing is mutated mid-flight.
func _embed_worker(gen: int, k: int, cache_path: String, idx, notes: Dictionary,
		warm: Dictionary, persist: bool) -> void:
	var embed := AreaEmbeddingScript.layout(idx.knn_graph(k),
		AreaEmbeddingScript.ITERATIONS, warm)
	var fingerprint := _fingerprint(notes)
	var doc := {"version": CACHE_VERSION, "fingerprint": fingerprint,
		"positions": _positions_to_cache(embed), "notes": notes}
	_mutex.lock()
	if gen == _generation:
		_positions = embed
		_cache_doc = doc
	_mutex.unlock()
	if persist:
		_save_cache(cache_path, doc)
	call_deferred("_emit_positions_ready", gen)

func _emit_positions_ready(gen: int) -> void:
	if _exiting or gen != _generation:
		return   # a newer rescan owns the state *and* the busy flag; its own
		        # completion clears it (see _emit_ready).
	_embed_busy = false
	if is_inside_tree():
		positions_ready.emit()
	_drain_pending()

## Apply queued invalidations now that every worker is idle, then reschedule
## the debounced embed. Called only from the workers' deferred completions
## (main thread), so the queue drains exactly once per completion.
func _drain_pending() -> void:
	if _pending.is_empty():
		return
	var rels := _pending.keys()
	_pending.clear()
	for rel in rels:
		_apply_invalidate(String(rel))
	_schedule_embed()

## Join the embed worker. Vault-switch/boot/teardown paths only — the typing
## path queues instead (see invalidate). The join clears the busy flag
## because the joined worker's deferred is stale by then (the caller has
## bumped the generation) and skips itself.
func _join_embed() -> void:
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()
	_embed_busy = false

# ---------------------------------------------------------------- cache file

## Sidecar path for a vault, keyed by the vault's own id file (survives a
## vault move, exactly like the sync identity); a scratch vault without one
## falls back to the hashed absolute path, so it can never collide with a
## real vault's cache. Always under user://, never inside the vault.
func _cache_path_for(vault: String) -> String:
	var id := TextIO.read_text(vault.path_join(VAULT_ID_FILE)).strip_edges()
	if id == "":
		id = String(vault).md5_text()
	return "user://tfidf-cache-%s.json" % id

## Order-stable fingerprint over the per-note content hashes: two scans of
## the same corpus produce the same value, so an unchanged vault reuses its
## cached embedding instead of recomputing it.
static func _fingerprint(notes: Dictionary) -> int:
	var h := 0
	var rels := notes.keys()
	rels.sort()
	for rel in rels:
		var entry: Dictionary = notes[rel]
		h = _mix32(h ^ String(str(rel) + "|" + str(int(entry.get("h", 0)))).hash())
	return h

## 32-bit avalanche (same shape as GraphView's route-speed mix).
static func _mix32(v: int) -> int:
	var x: int = v & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	return (x ^ (x >> 16)) & 0xFFFFFFFF

static func _save_cache(path: String, doc: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return  # the cache is an accelerator, never a requirement
	f.store_string(JSON.stringify(doc))
	f.close()

## {rel: [x, y]} (the JSON shape) -> {rel: Vector2}, filtered to live notes.
static func _positions_from_cache(cached: Variant, keep: Dictionary) -> Dictionary:
	var out := {}
	if typeof(cached) != TYPE_DICTIONARY:
		return out
	for rel in cached.keys():
		if not keep.has(rel):
			continue
		var pair: Array = cached[rel]
		if pair.size() == 2:
			out[String(rel)] = Vector2(float(pair[0]), float(pair[1]))
	return out

## {rel: Vector2} -> {rel: [x, y]} (the JSON shape).
static func _positions_to_cache(positions: Dictionary) -> Dictionary:
	var out := {}
	for rel in positions.keys():
		var p: Vector2 = positions[rel]
		out[String(rel)] = [p.x, p.y]
	return out

# ------------------------------------------------------------------ helpers

## A tag term folds into the bag this many times: a tag is a word the user
## curated as a subject marker, so it carries more signal than a single body
## mention — (1 + ln(3)) ≈ 2.1x the TF-IDF weight — and unlike body words,
## tags bridge languages (a #japan note is about Japan in any language).
const TAG_WEIGHT := 3

## Title + tags + body as one bag of words. Title and tag words live in
## front-matter (absent from `body()`), so they fold in here — titles once,
## tags `TAG_WEIGHT` times (see above). Any change to this bag changes every
## note's content hash: bump CACHE_VERSION so stale caches drop wholesale.
func _bag(text: String) -> String:
	var title := NoteMetadata.field(text, "title", "")
	var body := NoteMetadata.body(text)
	var parts: Array[String] = []
	if title != "":
		parts.append(title)
	for tag in _tag_terms(NoteMetadata.field(text, "tags", "")):
		for i in TAG_WEIGHT:
			parts.append(tag)
	parts.append(body)
	return " ".join(parts)

## A front-matter tags value ("alpha, beta, #gamma") as plain bag terms:
## comma-separated, leading '#' stripped, lowercased. A tag may itself
## contain spaces ("machine learning") — the tokeniser splits those into
## their words, which is exactly right for the bag.
static func _tag_terms(raw: String) -> Array[String]:
	var out: Array[String] = []
	for chunk in raw.split(","):
		var tag := chunk.strip_edges().trim_prefix("#").strip_edges()
		if tag != "":
			out.append(tag.to_lower())
	return out
