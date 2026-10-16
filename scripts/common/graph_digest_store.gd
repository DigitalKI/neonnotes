class_name GraphDigestStore extends Node
## Worker + cache behind the graph focus card.
##
## The card asks for a note's digest and gets whatever is already cached — a
## miss returns `{}` immediately and queues the read, so the UI never blocks on
## disk. A single `Thread` drains the queue (file read + `GraphDigest.summarize`)
## and hands results back on the main thread via `digest_ready`.
##
## Cache entries are keyed by vault-relative path and dropped by
## `invalidate()` (Main calls it when a note is saved) or `clear()` (vault
## switch / rescan). Cheap enough to be a plain Dictionary: one small record
## per note the user actually focused.

signal digest_ready(rel: String)

var _cache := {}          # rel -> Dictionary (GraphDigest.summarize result)
var _queued := {}         # rel -> true, dedupes pending requests
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _thread: Thread
var _exit := false
var _vault := ""

func _ready() -> void:
	_vault = GameManager.vault_abs()
	_thread = Thread.new()
	_thread.start(_worker)

func _exit_tree() -> void:
	# The worker checks `_exit` before touching the next item, so this wait is
	# bounded to one in-flight file read, not the whole queue.
	_exit = true
	_sem.post()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()

## Cached digest, or `{}` plus a queued read. Main-thread API.
func request(rel: String) -> Dictionary:
	if rel == "":
		return {}
	if _cache.has(rel):
		return _cache[rel]
	_mutex.lock()
	if not _queued.has(rel):
		_queued[rel] = true
		_mutex.unlock()
		_sem.post()
	else:
		_mutex.unlock()
	return {}

func cached(rel: String) -> bool:
	return _cache.has(rel)

## Drop one note (its text changed) so the next request re-reads it.
func invalidate(rel: String) -> void:
	_cache.erase(rel)

func clear() -> void:
	_cache.clear()
	_vault = GameManager.vault_abs()

# ------------------------------------------------------------------ worker

func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		var rel := ""
		for key in _queued.keys():
			rel = String(key)
			_queued.erase(key)
			break
		var exiting := _exit
		_mutex.unlock()
		if exiting:
			return
		if rel == "":
			continue
		var text: Variant = _read(rel)
		if text == null:
			_deliver(rel, {})
			continue
		_deliver(rel, GraphDigest.summarize(text))

## Null on a missing/unreadable file, so "gone" is not cached as a valid digest.
func _read(rel: String) -> Variant:
	var path := _vault.path_join(rel)
	if not FileAccess.file_exists(path):
		return null
	return TextIO.read_text(path)

## Store off-thread, notify on-thread: `call_deferred` re-enters the main loop,
## which is where UI code (the card) is allowed to run.
func _deliver(rel: String, digest: Dictionary) -> void:
	if digest.is_empty():
		call_deferred("_emit_ready", rel)
		return
	_mutex.lock()
	_cache[rel] = digest
	_mutex.unlock()
	call_deferred("_emit_ready", rel)

func _emit_ready(rel: String) -> void:
	if is_inside_tree():
		digest_ready.emit(rel)