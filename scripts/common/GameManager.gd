extends Node
## Global app state: vault location, color palettes, current note (NeonNotes v2).

signal palette_changed

const VAULT_DIR := "user://vault"
const SETTINGS := "user://settings.cfg"

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
var vault_dir := VAULT_DIR
var current_file := ""  # absolute path of the open note ("" = none)
var current_rel := ""   # vault-relative path of the open note ("" = none)
var notes: Array[String] = []

func _ready() -> void:
	_load_settings()
	DirAccess.make_dir_recursive_absolute(vault_abs())

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

func scan_notes() -> void:
	notes.clear()
	titles.clear()
	_scan_dir("")
	notes.sort()
	for n in notes:
		titles[n] = _read_title(n)

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
			if not f.begins_with("."):
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
	if not PALETTES.has(palette_name):
		palette_name = "Synthwave"
	vault_dir = cf.get_value("vault", "dir", VAULT_DIR)

func _save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ui", "palette", palette_name)
	cf.set_value("vault", "dir", vault_dir)
	cf.save(SETTINGS)
