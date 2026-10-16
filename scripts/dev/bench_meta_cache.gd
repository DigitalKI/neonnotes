extends Node
## Dev-only: cold vs warm timing of the boot metadata pass.
##   NEONNOTES_BENCH_VAULT=/tmp/nn-bigvault \
##     godot --headless --path . scenes/dev/BenchMetaCache.tscn
## "cold" = no user://metadata_index.json, "warm" = the cache the previous pass
## wrote. async = load_metadata_async (what Main boots with), sync = scan_notes.
## Assigns vault_dir directly and restores the cache file when done.

func _ready() -> void:
	var path := OS.get_environment("NEONNOTES_BENCH_VAULT")
	if path == "":
		path = "/tmp/nn-bigvault"
	GameManager.vault_dir = path
	var cache_abs := ProjectSettings.globalize_path(GameManager.META_CACHE)
	var backup := cache_abs + ".benchbak"
	var had := FileAccess.file_exists(cache_abs)
	if had:
		DirAccess.rename_absolute(cache_abs, backup)

	var cold_async := await _timed_async()   # no cache -> true cold; writes cache
	var warm_async := await _timed_async()   # cache present -> warm
	_drop(cache_abs)
	var cold_sync := _timed_sync()           # no cache -> true cold; writes cache
	var warm_sync := _timed_sync()           # cache present -> warm

	print("BENCH-META2 notes=%d async[cold=%dms warm=%dms] sync[cold=%dms warm=%dms]"
		% [GameManager.notes.size(), cold_async, warm_async, cold_sync, warm_sync])

	if OS.get_environment("NEONNOTES_BENCH_KEEP") != "1":
		_drop(cache_abs)
		if had and FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, cache_abs)
	get_tree().quit()

func _reset() -> void:
	GameManager._meta_cache = {}
	GameManager._meta_cache_vault = ""

func _timed_async() -> int:
	_reset()
	GameManager.scan_paths()
	var t0 := Time.get_ticks_msec()
	await GameManager.load_metadata_async()
	return Time.get_ticks_msec() - t0

func _timed_sync() -> int:
	_reset()
	GameManager.scan_paths()
	var t0 := Time.get_ticks_msec()
	GameManager._index_note_metadata()
	return Time.get_ticks_msec() - t0

func _drop(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
