extends Node
## Global app state: vault location, color palettes, current note (NeonNotes v2).

signal palette_changed

const VAULT_DIR := "user://vault"
const SETTINGS := "user://settings.cfg"
const FRONT_MATTER_SCAN_MAX_LINES := 200  # bound the per-keystroke front-matter scan
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
var links := {}   # relative path -> Array[String] outbound [[wiki-link]] targets
var links_ready := false  # true once scan_notes() has indexed the whole vault
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
	links.clear()
	_scan_dir("")
	_ensure_folder_notes()
	notes.sort()
	for n in notes:
		# One read per note yields title + tags + outbound links; the previous
		# code opened every note twice (once for the title, once for the tags).
		var meta := _read_note_meta(n)
		titles[n] = meta["title"]
		tags[n] = meta["tags"]
		links[n] = meta["links"]
	links_ready = true
	load_order()

## Remap the in-memory index after files moved on disk, without re-reading the
## vault. Only paths change on a move — titles/tags travel with their files —
## so this is exact and avoids a full rescan on every drag/drop.
## Matches the path itself, its children ("prefix/…") and its companion note.
func remap_moved(old_prefix: String, new_prefix: String) -> void:
	if old_prefix == "" or old_prefix == new_prefix:
		return
	var moved_notes: Array[String] = []
	for n in notes:
		moved_notes.append(PathRemap.moved(n, old_prefix, new_prefix))
	notes = moved_notes
	notes.sort()
	titles = PathRemap.moved_keys(titles, old_prefix, new_prefix)
	tags = PathRemap.moved_keys(tags, old_prefix, new_prefix)
	links = PathRemap.moved_keys(links, old_prefix, new_prefix)
	collapsed_folders = PathRemap.moved_keys(collapsed_folders, old_prefix, new_prefix)
	var moved_order := {}
	for dir in order.keys():
		var lst: Array = []
		for r in order[dir]:
			lst.append(PathRemap.moved(String(r), old_prefix, new_prefix))
		moved_order[PathRemap.moved(String(dir), old_prefix, new_prefix)] = lst
	order = moved_order

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

## One pass over a note producing its front-matter title and tags plus every
## outbound [[wiki-link]] target. Feeds the in-memory link index so backlinks,
## the graph view and post-move link rewriting never re-read the whole vault.
func _read_note_meta(fname: String) -> Dictionary:
	var f := FileAccess.open(vault_abs() + "/" + fname, FileAccess.READ)
	if f == null:
		return {"title": "", "tags": [] as Array[String], "links": [] as Array[String]}
	var text := f.get_as_text()
	f.close()
	return _parse_note_meta(text)

## The same extraction from text already in memory — write_note() uses it so
## saving a note refreshes its index entry for free.
func _parse_note_meta(text: String) -> Dictionary:
	var title := ""
	var tag_list: Array[String] = []
	# Front matter sits at the head of the file, so walk lines by index instead
	# of splitting the whole note — write_note() runs on every autosave.
	var total := text.length()
	var first_end := text.find("\n")
	if first_end < 0:
		first_end = total
	if text.substr(0, first_end).strip_edges() == "---":
		var line_start := first_end + 1
		var guard := 0
		while line_start <= total and guard < FRONT_MATTER_SCAN_MAX_LINES:
			guard += 1
			var nl := text.find("\n", line_start)
			if nl < 0:
				nl = total
			var line := text.substr(line_start, nl - line_start)
			if line.strip_edges() == "---":
				break
			var idx := line.find(":")
			if idx > 0:
				var key := line.substr(0, idx).strip_edges()
				if key == "title" and title == "":
					title = line.substr(idx + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
				elif key == "tags":
					var v := line.substr(idx + 1).strip_edges().trim_prefix("[").trim_suffix("]")
					for x in v.split(","):
						var tag := x.strip_edges().trim_prefix("\"").trim_suffix("\"").trim_prefix("#")
						if tag != "" and not tag_list.has(tag):
							tag_list.append(tag)
			line_start = nl + 1
	return {"title": title, "tags": tag_list, "links": extract_wiki_links(text)}

## Raw [[wiki-link]] targets in `text` (deduplicated, alias stripped). Lives here
## rather than in WikiLinks so GameManager can index links without a cyclic
## dependency; WikiLinks.extract_links() delegates to it.
static func extract_wiki_links(text: String) -> Array[String]:
	var result: Array[String] = []
	if not text.contains("[["):
		return result  # nothing to find — skip the regex on this hot path
	var re := RegEx.create_from_string("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	for m in re.search_all(text):
		var target := m.get_string(1).strip_edges()
		if target != "" and not result.has(target):
			result.append(target)
	return result

## Notes whose indexed outbound links could reference `old_prefix` (the full
## target, its bare file name, or a "dir/…" prefix). Post-move rewriting visits
## only these instead of reading every note in the vault.
func notes_linking_to(old_prefix: String) -> Array[String]:
	var out: Array[String] = []
	for n in notes:
		for t in links.get(n, []):
			if PathRemap.link_target_matches(String(t), old_prefix):
				out.append(n)
				break
	return out
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

## Vault-relative note paths straight from the directory tree, with no
## title/tag file reads — a cheap path list for link rewriting after a move.
func list_note_paths() -> Array[String]:
	var out: Array[String] = []
	_collect_note_paths("", out)
	return out

func _collect_note_paths(rel: String, out: Array[String]) -> void:
	var d := DirAccess.open(vault_dir + ("/" + rel if rel != "" else ""))
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var child := rel + ("/" if rel != "" else "") + f
		if d.current_is_dir():
			if not f.begins_with(".") and not (rel == "" and f == EXPORTS_SUBDIR):
				_collect_note_paths(child, out)
		elif f.ends_with(".md"):
			out.append(child)
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
	# Keep the in-memory note list deterministic for callers that write a note
	# before the next full scan.
	notes.sort()
	# Refresh this note's cached metadata from the text we already hold, so the
	# link index stays valid without a rescan (autosave, sync, link rewriting).
	var meta := _parse_note_meta(text)
	titles[fname] = meta["title"]
	tags[fname] = meta["tags"]
	links[fname] = meta["links"]
	return true

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
