extends Node
## Regression: the on-disk metadata index (GameManager META_CACHE) lets a warm
## boot rebuild titles/tags/links WITHOUT re-reading every note, and stays
## correct when a note changes, is added, or is moved.
##
## Assigns GameManager.vault_dir directly (never set_vault_dir, which persists
## the vault selection) and snapshots/restores user://metadata_index.json, so it
## can neither repoint the real vault nor damage the real cache.

const CACHE := "user://metadata_index.json"

var _fails := 0

func _check(cond: bool, what: String) -> void:
	print(("  ok  " if cond else "  FAIL ") + what)
	if not cond:
		_fails += 1

func _ready() -> void:
	var orig_vault := GameManager.vault_dir
	var orig_cache = _read_file(CACHE)

	var vault := "user://test-meta-cache"
	_rm(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault          # direct assign: never persists
	GameManager._meta_cache = {}
	GameManager._meta_cache_vault = ""

	GameManager.write_note("Alpha.md", "---\ntitle: \"Alpha\"\ntags: red, blue\n---\n\n# Alpha\nsee [[Beta]]\n")
	GameManager.write_note("Sub/Beta.md", "---\ntitle: \"Beta\"\n---\n\n# Beta\n")
	GameManager.scan_notes()               # cold: reads every note, builds cache

	_check(GameManager.titles.get("Alpha.md", "") == "Alpha", "cold read title")
	_check(GameManager.links.get("Alpha.md", []).has("Beta"), "cold read links")
	var cached: Dictionary = GameManager._meta_cache.get("Alpha.md", {})
	_check(typeof(cached) == TYPE_DICTIONARY and int(cached.get("s", -1)) > 0, "cache entry has size")

	# Warm boot: brand-new in-memory cache, loaded from disk.
	GameManager._meta_cache = {}
	GameManager._meta_cache_vault = ""
	GameManager._load_meta_cache()
	_check(GameManager._meta_cache.has("Alpha.md"), "cache survives reload from disk")

	# The real boot path: load_metadata_async fills titles/tags/links from the
	# cache (applied synchronously) instead of dripping them a batch per frame.
	GameManager.titles.clear()
	GameManager.tags.clear()
	GameManager.links.clear()
	await GameManager.load_metadata_async()
	_check(GameManager.titles.get("Alpha.md", "") == "Alpha", "warm pass fills titles from cache")
	_check(GameManager.links.get("Alpha.md", []).has("Beta"), "warm pass fills links from cache")
	_check(GameManager.titles.get("Sub/Beta.md", "") == "Beta", "warm pass covers nested notes")

	# A hit must NOT read the file: poison the cached title, read it back.
	GameManager._meta_cache["Alpha.md"]["t"] = "POISON"
	var hit := GameManager._meta_for("Alpha.md")
	_check(hit["title"] == "POISON", "mtime+size match -> cache hit (no file read)")
	GameManager._meta_cache["Alpha.md"]["t"] = "Alpha"

	# Changing the file on disk (outside write_note) invalidates the entry.
	var abs := GameManager.vault_abs() + "/Alpha.md"
	var w := FileAccess.open(abs, FileAccess.WRITE)
	w.store_string("---\ntitle: \"Alpha2\"\ntags: green\n---\n\n# Alpha2\n")
	w.close()
	var changed := GameManager._meta_for("Alpha.md")
	_check(changed["title"] == "Alpha2" and GameManager._meta_cache["Alpha.md"]["t"] == "Alpha2",
			"changed file re-read + re-cached")

	# An old/unknown cache version is ignored.
	var saved = _read_file(CACHE)
	_write_file(CACHE, "{\"version\": 999, \"vaults\": {}}")
	GameManager._meta_cache = {}
	GameManager._meta_cache_vault = ""
	GameManager._load_meta_cache()
	_check(GameManager._meta_cache.is_empty(), "version mismatch -> cache ignored")
	_write_file(CACHE, saved)

	# Helpers.
	_check(GameManager.file_size(abs) > 0, "file_size existing")
	_check(GameManager.file_size(GameManager.vault_abs() + "/nope.md") == -1, "file_size missing")
	_check(GameManager.as_string_array(["a", 2]).size() == 2, "as_string_array coerces")

	# A move drops the moved note's cache entry (its links may have been rewritten).
	GameManager._meta_cache["Sub/Beta.md"] = {"m": 0, "s": 0, "t": "Beta", "g": [], "l": []}
	GameManager.remap_moved("Sub", "Moved")
	_check(not GameManager._meta_cache.has("Sub/Beta.md"), "move drops stale cache entry")

	# Restore everything.
	GameManager.vault_dir = orig_vault
	GameManager._meta_cache = {}
	GameManager._meta_cache_vault = ""
	_rm(vault)
	if orig_cache == null:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE))
	else:
		_write_file(CACHE, orig_cache)

	print("META CACHE RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _read_file(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var t := f.get_as_text()
	f.close()
	return t

func _write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

func _rm(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs):
		var d := DirAccess.open(abs)
		if d:
			for f in d.get_files():
				d.remove(f)
			for sub in d.get_directories():
				_rm(dir + "/" + sub)
		DirAccess.remove_absolute(abs)
