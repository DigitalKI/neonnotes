class_name VaultSearchRunner
extends Node
## Debounced, cancellable search plumbing shared by the sidebar tree and the
## Move page: schedule a query on every keystroke, get one result set back
## after the pause, and let the previous run die without publishing.
##
## The node owns the Timer and the Thread, so neither surface has to repeat the
## "join the dead worker, respect the newest generation, retry while the old
## read is still running" dance. Workers only touch plain data (see
## VaultSearch.keyword_hits), never the scene tree or GameManager's mutable
## index: the main thread stays responsive.

## Emitted when a run actually starts (the caller can drop stale rows now).
signal started
## Emitted on the main thread with the newest run's results.
signal finished(generation: int, results: Array)

const DEBOUNCE_SECONDS := 0.35

var timer: Timer
var thread: Thread
## Bumped on every schedule()/invalidate(); a run only publishes for the
## generation it started with.
var generation := 0
## True while a scheduled run has not started yet.
var pending := false

var _names: Array = []
var _titles: Dictionary = {}
var _vault_path := ""
var _text := ""
var _cancel := false
var _run_generation := 0
var _shutting_down := false


func _ready() -> void:
	timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = DEBOUNCE_SECONDS
	timer.timeout.connect(_launch)
	add_child(timer)


## Queue a search for `text` over `names` (already narrowed by any #tags).
## `immediate` skips the debounce (a move/delete changed paths under the query).
func schedule(names: Array, titles: Dictionary, vault_path: String, text: String,
		immediate := false) -> void:
	if _shutting_down:
		return
	generation += 1
	_cancel = true
	_names = names
	_titles = titles
	_vault_path = vault_path
	_text = text
	pending = true
	timer.stop()
	if immediate:
		_launch()
	else:
		timer.start()


## Drop queued and in-flight work: a newer query (or teardown) owns the tree.
func invalidate() -> void:
	generation += 1
	_cancel = true
	pending = false
	if timer != null:
		timer.stop()


func _launch() -> void:
	if _shutting_down or thread != null:
		# Never rebuild while an older worker is still reading; _process()
		# retries as soon as it exits.
		return
	pending = false
	_cancel = false
	var gen := generation
	started.emit()
	if _text.length() < VaultSearch.MIN_KEYWORD:
		# Tag-only (or short text): the candidate list IS the answer. No disk.
		finished.emit(gen, _names.duplicate())
		return
	_run_generation = gen
	var cancelled := func() -> bool: return _cancel or _run_generation != generation
	# The worker gets its own title snapshot: the metadata index is rebuilt by a
	# scan/move on the main thread while the search reads.
	var titles := _titles.duplicate()
	thread = Thread.new()
	thread.start(VaultSearch.keyword_hits.bind(_names, titles, _vault_path, _text, cancelled))


func _process(_delta: float) -> void:
	# Poll at most once per frame; a call_deferred() loop could run many times
	# in one frame and starve input while the worker reads files.
	if thread != null and not thread.is_alive():
		var out: Variant = thread.wait_to_finish()
		thread = null
		var gen := _run_generation
		if not _shutting_down and not _cancel and gen == generation:
			finished.emit(gen, out if out is Array else [])
	if pending and thread == null and timer.is_stopped():
		_launch()


func _exit_tree() -> void:
	_shutting_down = true
	generation += 1
	_cancel = true
	pending = false
	if timer != null:
		timer.stop()
	# Joining is required before the node is freed: the worker captures this
	# instance through its cancellation/generation checks.
	if thread != null:
		thread.wait_to_finish()
		thread = null
