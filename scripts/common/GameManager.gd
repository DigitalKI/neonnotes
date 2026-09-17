extends Node
## Global app state: vault location, color palettes, current note (NeonNotes v2).

signal palette_changed

const VAULT_DIR := "user://vault"
const SETTINGS := "user://settings.cfg"
const EXPORTS_SUBDIR := "exports"  # vault/exports/ — rendered PNG/GIF/HTML, hidden from the tree

const PALETTES := {
	"Synthwave": {
		"bg": Color("14062b"), "panel": Color("1d0d3a"), "text": Color("f2e9ff"),
		"accent": Color("ff2ea6"), "accent2": Color("00e5ff"),
		"accent3": Color("ffb400"), "accent4": Color("8a2be2"),
	},
	"Midnight Drive": {
		"bg": Color("0a0f1e"), "panel": Color("101a30"), "text": Color("e6f1ff"),
		"accent": Color("00ffc8"), "accent2": Color("ff5f6d"),
		"accent3": Color("ffd166"), "accent4": Color("6c63ff"),
	},
	"Toxic Terminal": {
		"bg": Color("07130d"), "panel": Color("0d2418"), "text": Color("e0ffe8"),
		"accent": Color("39ff14"), "accent2": Color("ff2ea6"),
		"accent3": Color("00e5ff"), "accent4": Color("ffb400"),
	},
	"Arcade Sunset": {
		"bg": Color("1a0a12"), "panel": Color("2a1220"), "text": Color("ffe9f2"),
		"accent": Color("ff6b35"), "accent2": Color("ffd23f"),
		"accent3": Color("f72585"), "accent4": Color("4cc9f0"),
	},
}

var palette_name := "Synthwave"
var graph_levels := 2
var export_crt := true  # apply CRT overlay to exported PNG/JPEG/GIF
var open_start_mode := "last"  # "last" or "homepage"
var last_opened_rel := ""
var vault_dir := VAULT_DIR
var current_file := ""  # absolute path of the open note ("" = none)
var current_rel := ""   # vault-relative path of the open note ("" = none)
var notes: Array[String] = []

# Sync identity: a stable 4-word code (e.g. "amber-meteor-vinyl-orbit") that
# uniquely identifies this device on the LAN, plus the set of device codes we
# have successfully paired with (trusted → no PIN needed again).
var device_id := ""
var trusted: Array[String] = []
var sync_pin := ""
var vault_id := ""
var paired_vault_id := ""
var paired_peers: Dictionary = {} # device_id -> {name, vault_id, pin}

func _ready() -> void:
	_load_settings()
	DirAccess.make_dir_recursive_absolute(vault_abs())
	if device_id == "":
		device_id = SyncService.gen_device_code()
	if vault_id == "":
		vault_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	_save_settings()

# ------------------------------------------------------------ palette

func palette() -> Dictionary:
	return PALETTES[palette_name]

func color(key: String) -> Color:
	return palette()[key]

func set_palette(name: String) -> void:
	if PALETTES.has(name) and name != palette_name:
		palette_name = name
		palette_changed.emit()
		_save_settings()

## Toggle the CRT overlay on exports. Persists so it survives restarts.
func set_export_crt(on: bool) -> void:
	export_crt = on
	_save_settings()

# ------------------------------------------------------------ vault

func vault_abs() -> String:
	return ProjectSettings.globalize_path(vault_dir)

## Desktop: open any folder as the vault (Git/Dropbox friendly). Persists.
func set_vault_dir(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return false
	vault_dir = path
	current_file = ""
	_save_settings()
	scan_notes()
	return true

var titles := {}  # relative path -> front-matter title ("" = use filename)
var tags := {}    # relative path -> Array[String] from front-matter "tags:"
# custom sort order per folder: {"folder/sub": ["note.md", …]} persisted in
# vault/.neonnotes.json (synced like a note, tiny and human-readable)
const ORDER_FILE := ".neonnotes.json"
var order := {}
var collapsed_folders: Dictionary = {}

func load_order() -> void:
	order = {}
	collapsed_folders = {}
	var f := FileAccess.open(vault_abs() + "/" + ORDER_FILE, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if typeof(data) == TYPE_DICTIONARY:
		if typeof(data.get("order", {})) == TYPE_DICTIONARY:
			order = data["order"]
		if typeof(data.get("collapsed", {})) == TYPE_DICTIONARY:
			collapsed_folders = data["collapsed"]

func save_order() -> void:
	var f := FileAccess.open(vault_abs() + "/" + ORDER_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"order": order, "collapsed": collapsed_folders}, "  "))
	f.close()

func scan_notes() -> void:
	notes.clear()
	titles.clear()
	tags.clear()
	_scan_dir("")
	_ensure_folder_notes()
	notes.sort()
	for n in notes:
		titles[n] = _read_title(n)
		tags[n] = _read_tags(n)
	load_order()

## Every folder that shows in the tree is also a note: if `folder.md` doesn't
## exist, create it (fixes vaults made before folder+note merging).
const FOLDER_NOTE_TEMPLATE := "---\ntitle: \"%s\"\n---\n\n# %s\n"

func _ensure_folder_notes() -> void:
	var found := notes.duplicate()
	for n in found:
		if not n.ends_with(".md"):
			continue
		var dir: String = n.get_base_dir()
		while dir != "":
			var comp: String = dir + ".md"
			if not notes.has(comp):
				write_note(comp, FOLDER_NOTE_TEMPLATE % [dir.get_file(), dir.get_file()])
				notes.append(comp)
			dir = dir.get_base_dir() if dir.contains("/") else ""

## Collect tags from front-matter across all notes (deduplicated, sorted).
func all_tags() -> Array[String]:
	var out: Array[String] = []
	for t in tags.values():
		for x in t:
			if not out.has(x):
				out.append(x)
	out.sort()
	return out

## Front-matter "tags: a, b" or "tags: [a, b]" → Array[String]
func _read_tags(fname: String) -> Array[String]:
	var f := FileAccess.open(vault_abs() + "/" + fname, FileAccess.READ)
	if f == null:
		return []
	var first := f.get_line()
	if first.strip_edges() != "---":
		return []
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "---":
			break
		var idx := line.find(":")
		if idx > 0 and line.substr(0, idx).strip_edges() == "tags":
			var v := line.substr(idx + 1).strip_edges().trim_prefix("[").trim_suffix("]")
			var out: Array[String] = []
			for x in v.split(","):
				var tag := x.strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("#")
				if tag != "" and not out.has(tag):
					out.append(tag)
			return out
	return []

## Peek at the front-matter title without parsing the whole file.
func _read_title(fname: String) -> String:
	var f := FileAccess.open(vault_abs() + "/" + fname, FileAccess.READ)
	if f == null:
		return ""
	var first := f.get_line()
	if first.strip_edges() != "---":
		f.close()
		return ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "---":
			break
		var idx := line.find(":")
		if idx > 0 and line.substr(0, idx).strip_edges() == "title":
			f.close()
			return line.substr(idx + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	f.close()
	return ""
## Recursive walk; notes store vault-relative paths ("folder/sub/note.md")
func _scan_dir(rel: String) -> void:
	var d := DirAccess.open(vault_dir + ("/" + rel if rel != "" else ""))
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var child := rel + ("/" if rel != "" else "") + f
		if d.current_is_dir():
			if not f.begins_with(".") and not (rel == "" and f == EXPORTS_SUBDIR):
				_scan_dir(child)
		elif f.ends_with(".md"):
			notes.append(child)
		f = d.get_next()
	d.list_dir_end()

## Create note in a folder (creating parent dirs as needed)
func write_note(fname: String, text: String) -> bool:
	var abs := vault_abs() + "/" + fname
	var dir := abs.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true
	notes.sort()

func read_note(fname: String) -> String:
	var f := FileAccess.open(vault_abs() + "/" + fname, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

# --------------------------------------------------------- persistence

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS) != OK:
		return
	palette_name = cf.get_value("ui", "palette", palette_name)
	export_crt = bool(cf.get_value("export", "crt", export_crt))
	graph_levels = clampi(int(cf.get_value("ui", "graph_levels", graph_levels)), 1, 10)
	open_start_mode = String(cf.get_value("ui", "open_start_mode", open_start_mode))
	if open_start_mode != "last" and open_start_mode != "homepage":
		open_start_mode = "last"
	last_opened_rel = String(cf.get_value("ui", "last_opened_rel", last_opened_rel))
	if not PALETTES.has(palette_name):
		palette_name = "Synthwave"
	vault_dir = cf.get_value("vault", "dir", VAULT_DIR)
	device_id = cf.get_value("sync", "device_id", "")
	sync_pin = cf.get_value("sync", "pin", "")
	vault_id = cf.get_value("sync", "vault_id", "")
	paired_vault_id = cf.get_value("sync", "paired_vault_id", "")
	paired_peers = cf.get_value("sync", "paired_peers", {})
	trusted.clear()
	for t in cf.get_value("sync", "trusted", []):
		trusted.append(String(t))

func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ui", "palette", palette_name)
	cf.set_value("export", "crt", export_crt)
	cf.set_value("ui", "graph_levels", graph_levels)
	cf.set_value("ui", "open_start_mode", open_start_mode)
	cf.set_value("ui", "last_opened_rel", last_opened_rel)
	cf.set_value("vault", "dir", vault_dir)
	cf.set_value("sync", "device_id", device_id)
	cf.set_value("sync", "pin", sync_pin)
	cf.set_value("sync", "vault_id", vault_id)
	cf.set_value("sync", "paired_vault_id", paired_vault_id)
	cf.set_value("sync", "paired_peers", paired_peers)
	cf.set_value("sync", "trusted", trusted)
	cf.save(SETTINGS)

func add_trusted(id: String) -> void:
	if id != "" and not trusted.has(id):
		trusted.append(id)
		_save_settings()
