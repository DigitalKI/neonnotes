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
## the cached positions so an edit shifts only its own neighbourhood. A note
## save re-indexes synchronously, re-embeds on the worker and re-persists the
## cache. Both workers are join-serialized (a new run waits for an in-flight
## one), so the main thread never mutates state a worker still reads.

signal index_ready
signal positions_ready

const TfidfIndexScript := preload("res://scripts/common/tfidf_index.gd")
const AreaEmbeddingScript := preload("res://scripts/common/area_embedding.gd")

## Cache format version; a mismatch (or corrupt JSON) drops the file and falls
## back to one full scan, so the cache is always an accelerator, never a
## requirement.
const CACHE_VERSION := 1
const VAULT_ID_FILE := ".neonnotes-id"

## k for the neighbour graph the embedding consumes; the shell owns the knob.
var embed_k := 3

var _index = TfidfIndexScript.new()
var _positions := {}
var _cache_doc := {}    # the whole sidecar document (version/fingerprint/positions/notes)
var _vault := ""
var _generation := 0
var _mutex := Mutex.new()
var _thread: Thread
var _embed_thread: Thread
## Provenance of the last scan — {notes, cached, read, tokenized,
## reused_positions} — published under the same mutex as the results; tests
## and the bench read it. Empty until the first scan completes.
var last_scan := {}

func _exit_tree() -> void:
	# `rescan()` joins any in-flight scan before starting a new one, and the
	# embed worker is joined the same way, so these waits are bounded to a
	# single pass, never the whole vault.
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

## Start a full-vault scan on the worker. Call once the vault's note list is
## final (after metadata_ready); a repeat call replaces any in-flight scan.
## The worker backfills from the sidecar cache, embeds (warm-started when the
## corpus changed, reused verbatim when it did not), delivers both, then
## re-persists the cache — nothing touches the main thread.
func rescan() -> void:
	_generation += 1
	_vault = GameManager.vault_abs()
	var gen := _generation
	var vault := _vault
	var names: Array[String] = GameManager.notes.duplicate()
	var k := embed_k
	var cache_path := _cache_path_for(vault)
	_join_embed()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_scan_worker.bind(gen, vault, names, k, cache_path))

## The sidecar cache path for the current vault (tests clean it up).
func cache_path() -> String:
	return _cache_path_for(_vault if _vault != "" else GameManager.vault_abs())

## The whole-vault Area View embedding ({note: Vector2} in map space, from
## `AreaEmbedding`); empty until the scan has delivered. The view falls back
## to the island-grid layout while it is empty (ADR-0016).
func area_positions() -> Dictionary:
	return _positions

## Top-k TF-IDF neighbours for a note; empty until the scan has indexed it.
func top_neighbors(rel: String, k: int) -> Array:
	return _index.top_neighbors(rel, k)

## Re-index one note after its text changed (editor save path), then re-embed
## on the worker — an edit changes similarity, so the Area View follows — and
## update the sidecar cache so the next boot sees the edit. Joins any
## in-flight embed first: the worker must never read an index being mutated.
func invalidate(rel: String) -> void:
	_join_embed()
	var abs := _vault.path_join(rel)
	var text := TextIO.read_text(abs)
	var bag := _bag(text)
	_index.index_note(rel, bag)
	var key := String(rel)
	if typeof(_cache_doc.get("notes")) != TYPE_DICTIONARY:
		_cache_doc["notes"] = {}
	_cache_doc["notes"][key] = {"m": int(FileAccess.get_modified_time(abs)),
		"h": bag.hash(), "tf": _index.term_counts(key)}
	_reembed()

## Drop the index, embedding and cache document on vault switch / import /
## restore. The sidecar file itself stays (keyed per vault) and is simply
## reloaded by the next rescan of the same vault.
func clear() -> void:
	_join_embed()
	_index = TfidfIndexScript.new()
	_positions = {}
	_cache_doc = {}
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
	if gen == _generation and is_inside_tree():
		index_ready.emit()
		positions_ready.emit()

## Re-embed the current index on the worker, warm-started from the current
## positions, and re-persist the cache. Serialized like the scan: a new run
## joins any in-flight embed first, so the main thread never mutates the
## state a running worker still reads.
func _reembed() -> void:
	_join_embed()
	var gen := _generation
	var k := embed_k
	var cache_path := _cache_path_for(_vault)
	var idx = _index      # quiescent: joined above, the next mutation joins us
	var notes = _cache_doc.get("notes", {})
	var warm = _positions
	_embed_thread = Thread.new()
	_embed_thread.start(_embed_worker.bind(gen, k, cache_path, idx, notes, warm))

func _embed_worker(gen: int, k: int, cache_path: String, idx, notes: Dictionary,
		warm: Dictionary) -> void:
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
	_save_cache(cache_path, doc)
	call_deferred("_emit_positions_ready", gen)

func _emit_positions_ready(gen: int) -> void:
	if gen == _generation and is_inside_tree():
		positions_ready.emit()

func _join_embed() -> void:
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()

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

## Title + body as one bag of words. Title words live in front-matter (absent
## from `body()`), so fold them in once — high-signal subject words.
func _bag(text: String) -> String:
	var title := NoteMetadata.field(text, "title", "")
	var body := NoteMetadata.body(text)
	if title == "":
		return body
	return title + " " + body