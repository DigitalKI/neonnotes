extends SceneTree
## Dev-only benchmark: how long does the boot-time vault scan take?
## Run headless:  godot --headless --path . --script scripts/dev/bench_scan.gd
## Never touches the real vault or settings (assigns vault_dir directly and
## suppresses the settings write, per the project invariant).

const COUNTS := [200, 1000]
const BODY_LINES := 40
const GameManagerScript := preload("res://scripts/common/GameManager.gd")

func _init() -> void:
	# Built directly (not via the autoload) so this can run as a `--script`
	# MainLoop, which has no autoload nodes.
	var gm: Node = GameManagerScript.new()
	gm.suppress_settings_save = true
	var base := "user://bench-vault"
	_rm_dir(base)
	for n in COUNTS:
		var dir := base + "/%d" % n
		_seed(dir, n)
		gm.vault_dir = dir
		# Warm the OS file cache, then measure.
		gm.scan_notes()
		var t0 := Time.get_ticks_msec()
		gm.scan_notes()
		var full_ms := Time.get_ticks_msec() - t0
		t0 = Time.get_ticks_msec()
		_scan_head_only(dir)
		var head_ms := Time.get_ticks_msec() - t0
		print("BENCH notes=%d full_scan=%dms head_scan=%dms index=%d" % [n, full_ms, head_ms, gm.notes.size()])
	gm.free()
	_rm_dir(base)
	quit()

func _seed(dir: String, n: int) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for i in n:
		var folder := "Folder%d" % (i % 12)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/" + folder))
		var body := "# Note %d\n\n" % i
		for l in BODY_LINES:
			body += "Line %d with some words and a [[Note %d]] link.\n" % [l, (i + l) % n]
		var text := "---\ntitle: \"Note %d\"\ntags: alpha, beta\ncreated: 2026-01-01T00:00:00\nupdated: 2026-01-02T00:00:00\n---\n\n" % i + body
		var f := FileAccess.open(dir + "/" + folder + "/Note%04d.md" % i, FileAccess.WRITE)
		f.store_string(text)
		f.close()

## Mirrors the *front-matter* part of GameManager._parse_note_meta but reads only
## the head of each file — the candidate optimization for the boot scan.
func _scan_head_only(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	var titles := 0
	for path in _walk(abs):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var head := f.get_buffer(mini(f.get_length(), 512))
		f.close()
		var text := head.get_string_from_utf8()
		if text.find("\ntitle:") >= 0 or text.begins_with("title:"):
			titles += 1

func _walk(abs: String) -> Array:
	var out: Array = []
	for d in DirAccess.get_directories_at(abs):
		out.append_array(_walk(abs.path_join(d)))
	for f in DirAccess.get_files_at(abs):
		if f.ends_with(".md"):
			out.append(abs.path_join(f))
	return out

func _rm_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	for d in DirAccess.get_directories_at(abs):
		_rm_dir(abs.path_join(d))
	for f in DirAccess.get_files_at(abs):
		DirAccess.remove_absolute(abs.path_join(f))
	DirAccess.remove_absolute(abs)
