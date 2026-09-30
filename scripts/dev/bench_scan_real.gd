extends Node
## Dev-only: profile GameManager.scan_notes() sub-phases on a real vault copy.
##   NEONNOTES_BENCH_VAULT=/tmp/nn_vault/files/vault \
##     godot --headless --path . scenes/dev/BenchScanReal.tscn

func _ready() -> void:
	var path := OS.get_environment("NEONNOTES_BENCH_VAULT")
	if path == "":
		path = "/tmp/nn_vault/files/vault"
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = path

	GameManager.scan_notes()  # warm the OS cache

	var t0 := Time.get_ticks_msec()
	GameManager.scan_notes()
	var full_ms := Time.get_ticks_msec() - t0
	var count := GameManager.notes.size()

	GameManager.notes.clear()
	GameManager.titles.clear()
	GameManager.tags.clear()
	GameManager.links.clear()
	t0 = Time.get_ticks_msec()
	GameManager._scan_dir("")
	var scan_dir_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	GameManager._ensure_folder_notes()
	var folder_ms := Time.get_ticks_msec() - t0

	GameManager.notes.sort()
	t0 = Time.get_ticks_msec()
	for n in GameManager.notes:
		GameManager._read_note_meta(n)
	var meta_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	GameManager.load_order()
	var order_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	var heads := 0
	for n in GameManager.notes:
		if _head_has_front_matter(GameManager.vault_abs() + "/" + n):
			heads += 1
	var head_ms := Time.get_ticks_msec() - t0

	print("BENCH-SCAN notes=%d full=%dms [walk=%d folder=%d meta=%d order=%d] head_scan=%dms (%d with fm)"
		% [count, full_ms, scan_dir_ms, folder_ms, meta_ms, order_ms, head_ms, heads])
	get_tree().quit()


## Stand-in for the boot optimization: read only up to the front-matter close
## instead of the whole file.
func _head_has_front_matter(abs_path: String) -> bool:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return false
	var first := f.get_line()
	if first.strip_edges() != "---":
		f.close()
		return false
	var lines := 1
	while lines < 200 and not f.eof_reached():
		var line := f.get_line()
		lines += 1
		if line.strip_edges() == "---":
			f.close()
			return true
	f.close()
	return false
