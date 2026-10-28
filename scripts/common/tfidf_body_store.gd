class_name TfidfBodyStore
extends Node
## Worker + cache behind the Area View semantic index (ADR-0013 / ADR-0016).
##
## Builds a body-word TF-IDF index over the whole vault on a worker thread, so
## the one-time scan never blocks the boot (INV-015), and embeds the k-NN
## similarity graph into Area View positions in the same pass. Exposes the
## whole-vault embedding (`area_positions()`) and per-note top-k neighbours;
## invalidated per note on save (re-index synchronously, re-embed on the
## worker) and cleared on vault switch. Mirrors GraphDigestStore's
## single-worker + deferred-delivery shape, extended by the same discipline
## for the embed worker: a new run always joins an in-flight one first.

signal index_ready
signal positions_ready

const TfidfIndexScript := preload("res://scripts/common/tfidf_index.gd")
const AreaEmbeddingScript := preload("res://scripts/common/area_embedding.gd")

## k for the neighbour graph the embedding consumes; the shell owns the knob.
var embed_k := 3

var _index = TfidfIndexScript.new()
var _positions := {}
var _vault := ""
var _generation := 0
var _mutex := Mutex.new()
var _thread: Thread
var _embed_thread: Thread

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
## The worker indexes every note, embeds the k-NN graph, then delivers both —
## the embedding never touches the main thread.
func rescan() -> void:
	_generation += 1
	_vault = GameManager.vault_abs()
	var gen := _generation
	var vault := _vault
	var names: Array[String] = GameManager.notes.duplicate()
	var k := embed_k
	_join_embed()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_scan_worker.bind(gen, vault, names, k))

## The whole-vault Area View embedding ({note: Vector2} in map space, from
## `AreaEmbedding`); empty until the scan has delivered. The view falls back
## to the island-grid layout while it is empty (ADR-0016).
func area_positions() -> Dictionary:
	return _positions

## Top-k TF-IDF neighbours for a note; empty until the scan has indexed it.
func top_neighbors(rel: String, k: int) -> Array:
	return _index.top_neighbors(rel, k)

## Re-index one note after its text changed (editor save path), then re-embed
## on the worker — an edit changes similarity, so the Area View follows.
func invalidate(rel: String) -> void:
	var text := TextIO.read_text(_vault.path_join(rel))
	_index.index_note(rel, _bag(text))
	_reembed()

## Drop the index and embedding on vault switch / import / restore.
func clear() -> void:
	_index = TfidfIndexScript.new()
	_positions = {}
	_vault = GameManager.vault_abs()

# ------------------------------------------------------------------ workers

func _scan_worker(gen: int, vault: String, names: Array[String], k: int) -> void:
	var idx = TfidfIndexScript.new()
	for rel in names:
		var text := TextIO.read_text(vault.path_join(String(rel)))
		idx.index_note(String(rel), _bag(text))
	var embed := AreaEmbeddingScript.layout(idx.knn_graph(k))
	_mutex.lock()
	if gen == _generation:
		_index = idx
		_positions = embed
	_mutex.unlock()
	call_deferred("_emit_ready", gen)

func _emit_ready(gen: int) -> void:
	if gen == _generation and is_inside_tree():
		index_ready.emit()
		positions_ready.emit()

## Re-embed the current index on the worker. Serialized like the scan: a new
## run joins any in-flight embed first, so the main thread never mutates the
## index a running worker still reads.
func _reembed() -> void:
	_join_embed()
	var gen := _generation
	var k := embed_k
	var idx = _index  # quiescent: joined above, the next mutation joins us
	_embed_thread = Thread.new()
	_embed_thread.start(_embed_worker.bind(gen, k, idx))

func _embed_worker(gen: int, k: int, idx) -> void:
	var embed := AreaEmbeddingScript.layout(idx.knn_graph(k))
	_mutex.lock()
	if gen == _generation:
		_positions = embed
	_mutex.unlock()
	call_deferred("_emit_positions_ready", gen)

func _emit_positions_ready(gen: int) -> void:
	if gen == _generation and is_inside_tree():
		positions_ready.emit()

func _join_embed() -> void:
	if _embed_thread != null and _embed_thread.is_started():
		_embed_thread.wait_to_finish()

# ------------------------------------------------------------------ helpers

## Title + body as one bag of words. Title words live in front-matter (absent
## from `body()`), so fold them in once — high-signal subject words.
func _bag(text: String) -> String:
	var title := NoteMetadata.field(text, "title", "")
	var body := NoteMetadata.body(text)
	if title == "":
		return body
	return title + " " + body