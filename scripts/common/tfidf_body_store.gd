class_name TfidfBodyStore
extends Node
## Worker + cache behind the Area View semantic index (ADR-0013 / Area View).
##
## Builds a body-word TF-IDF index over the whole vault on a worker thread, so
## the one-time scan never blocks the boot (INV-015). Exposes top-k neighbours
## for any note; invalidated per note on save and cleared on vault switch.
## Mirrors GraphDigestStore's single-worker + deferred-delivery shape.

signal index_ready

const TfidfIndexScript := preload("res://scripts/common/tfidf_index.gd")

var _index = TfidfIndexScript.new()
var _vault := ""
var _generation := 0
var _mutex := Mutex.new()
var _thread: Thread

func _exit_tree() -> void:
	# `rescan()` joins any in-flight scan before starting a new one, so this
	# wait is bounded to a single note read, not the whole vault.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

## Start a full-vault scan on the worker. Call once the vault's note list is
## final (after metadata_ready); a repeat call replaces any in-flight scan.
func rescan() -> void:
	_generation += 1
	_vault = GameManager.vault_abs()
	var gen := _generation
	var vault := _vault
	var names: Array[String] = GameManager.notes.duplicate()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_scan_worker.bind(gen, vault, names))

## Top-k TF-IDF neighbours for a note; empty until the scan has indexed it.
func top_neighbors(rel: String, k: int) -> Array:
	return _index.top_neighbors(rel, k)

## Re-index one note after its text changed (editor save path).
func invalidate(rel: String) -> void:
	var text := TextIO.read_text(_vault.path_join(rel))
	_index.index_note(rel, _bag(text))

## Drop the whole index on vault switch / import / restore.
func clear() -> void:
	_index = TfidfIndexScript.new()
	_vault = GameManager.vault_abs()

# ------------------------------------------------------------------ worker

func _scan_worker(gen: int, vault: String, names: Array[String]) -> void:
	var idx = TfidfIndexScript.new()
	for rel in names:
		var text := TextIO.read_text(vault.path_join(String(rel)))
		idx.index_note(String(rel), _bag(text))
	_mutex.lock()
	if gen == _generation:
		_index = idx
	_mutex.unlock()
	call_deferred("_emit_ready", gen)

func _emit_ready(gen: int) -> void:
	if gen == _generation and is_inside_tree():
		index_ready.emit()

## Title + body as one bag of words. Title words live in front-matter (absent
## from `body()`), so fold them in once — high-signal subject words.
func _bag(text: String) -> String:
	var title := NoteMetadata.field(text, "title", "")
	var body := NoteMetadata.body(text)
	if title == "":
		return body
	return title + " " + body
