extends Node
## Global app state: vault location, color palettes, current note (NeonNotes v2).

signal palette_changed
## Emitted when the UI font family or font size changes, so the shell can
## re-apply fonts and re-render the preview/editor.
signal font_changed
## Emitted when the background metadata pass (load_metadata_async) has filled
## titles/tags/links for the whole vault. Backlinks/graph/search can then refresh.
signal metadata_ready
## Emitted when the active vault's sync identity changes in place (unpair or
## reset words) so the shell can refresh its sync indicator.
signal sync_identity_changed
## Emitted when the live CRT overlay master switch changes (see `crt_ui`).
signal crt_ui_changed(enabled: bool)

const VAULT_DIR := "user://vault"
const SETTINGS := "user://settings.cfg"
const FRONT_MATTER_SCAN_MAX_LINES := 200  # bound the per-keystroke front-matter scan
const EXPORTS_SUBDIR := "exports"  # vault/exports/ — rendered PNG/GIF/HTML, hidden from the tree
## Non-secret vault id stored in the vault folder (never synced). Binds a
## folder to its device-local sync phrase + trusted peers.
const VAULT_ID_FILE := ".neonnotes-id"
## Editor/MCP session detection + the disposable vault such a run uses, so
## agent-driven UI checks can never read or write the user's real vault.
const DevSession := preload("res://scripts/common/dev_session.gd")

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
## Selectable UI fonts. "Share Tech Mono" is the original body/mono face;
## "VT323" is a CRT/VT terminal face that matches the synthwave + scanline
## identity. Headings, the note title and toolbar keep Orbitron (the display
## face) — this setting swaps the body/label/editor font.
const FONTS := {
	"Share Tech Mono": "res://assets/fonts/ShareTechMono-Regular.ttf",
	"VT323": "res://assets/fonts/VT323-Regular.ttf",
}
const DEFAULT_FONT := "Share Tech Mono"
## Baseline UI/body point size. The stored font_size is applied as a delta on
## top of every authored size, so the default (16) reproduces the old look.
const BASE_FONT_SIZE := 16
const MIN_FONT_SIZE := 12
const MAX_FONT_SIZE := 28

var font_name := DEFAULT_FONT
var font_size := BASE_FONT_SIZE
var _font_cache: Dictionary = {}
var graph_levels := 2
var export_crt := true  # apply CRT overlay to exported PNG/JPEG/GIF
var crt_ui := true  # live CRT overlay on the UI — master switch for CRT FX
var open_start_mode := "last"  # "last" or "homepage"
var last_opened_rel := ""
var vault_dir := VAULT_DIR
var dev_session := false  # true when this run is editor/MCP-driven (isolated vault)
var current_file := ""  # absolute path of the open note ("" = none)
var current_rel := ""   # vault-relative path of the open note ("" = none)
var notes: Array[String] = []

# Sync identity is split by scope: the device code is global (it names *this
# machine* on the LAN), while the vault phrase + trusted peers are per-vault,
# keyed by the vault's non-secret id (which lives in the vault folder). A
# phrase never leaves the device — peers only ever see a proof of it.
var device_id := ""
var sync_pin := ""  # legacy setting, no longer used for pairing
## Device-local per-vault identities: vault_id ->
## {secret, trusted, paired_peers, paired_vault_id}.
var sync_vaults: Dictionary = {}
## Live view of the ACTIVE vault's identity (mirrors sync_vaults[vault_id]).
var vault_secret := ""
var vault_id := ""
var paired_vault_id := ""
var paired_peers: Dictionary = {} # device_id -> {name, vault_id, ip}
var trusted: Array[String] = []
## A pre-per-vault global vault id, reused once so the migration keeps the
## user's existing pairing with the vault that was open.
var _legacy_vault_id := ""

func _ready() -> void:
	_load_settings()
	# An explicitly-marked agent/test session (MCP `play_scene` sets
	# NEONNOTES_DEV=1, or NEONNOTES_VAULT is set) must run against a disposable
	# vault and must not persist anything. Do this BEFORE make_dir/_save_settings
	# so the real vault is never touched. Normal runs are never redirected.
	if is_dev_session():
		_apply_dev_isolation()
	DirAccess.make_dir_recursive_absolute(vault_abs())
	if device_id == "":
		device_id = SyncService.gen_device_code()
	# The vault's non-secret id lives in the folder; the phrase + peers are
	# device-local and looked up by that id.
	ensure_vault_id()
	_load_vault_identity()
	_drop_self_trust()  # a device can never be its own peer
	_save_settings()

## True when this process is an explicitly-marked development/agent session
## (godot-mcp `play_scene` sets NEONNOTES_DEV=1, or NEONNOTES_VAULT is set).
## Normal desktop/editor Play runs and the shipped app are NOT dev sessions —
## they keep the real vault and sync identity. See DevSession.
static func is_dev_session() -> bool:
	return DevSession.is_active()

## Redirect a dev session to a scratch vault and neutralise everything that
## would leak into the user's real state: the vault path is assigned directly
## (never via set_vault_dir, which persists), _save_settings() is suppressed,
## and any loaded pairing is dropped so a test session cannot auto-reconnect and
## exchange notes with a real peer. Mirrors Main._prepare_smoke_vault().
func _apply_dev_isolation() -> void:
	dev_session = true
	var scratch := OS.get_environment(DevSession.ENV_VAULT)
	if scratch == "":
		scratch = DevSession.DEFAULT_VAULT
	vault_dir = scratch
	suppress_settings_save = true  # never repoint/persist the user's real vault
	current_file = ""
	current_rel = ""
	order.clear()
	collapsed_folders.clear()
	sync_vaults.clear()
	vault_secret = ""
	vault_id = ""
	_legacy_vault_id = ""
	trusted.clear()
	paired_peers.clear()
	paired_vault_id = ""
	print("[dev] isolated session — vault=%s (real vault untouched)" % vault_abs())

## Repair legacy settings that recorded this device's own id as a paired peer
## (UDP loopback + a same-device instance authenticating to itself).
func _drop_self_trust() -> void:
	var changed := false
	if trusted.has(device_id):
		trusted.erase(device_id)
		changed = true
	if paired_peers.has(device_id):
		paired_peers.erase(device_id)
		changed = true
	if changed:
		print("[Sync] removed self entry from trusted peers (device paired with itself)")
		_save_vault_identity()

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

## Toggle the live CRT overlay on the UI. This is the master switch for CRT FX:
## when off the overlay is hidden AND exports skip it too (see
## `crt_export_allowed`). The per-export choice in `export_crt` is preserved so
## it comes back unchanged when the overlay is re-enabled.
func set_crt_ui(on: bool) -> void:
	if on == crt_ui:
		return
	crt_ui = on
	crt_ui_changed.emit(on)
	_save_settings()

## True when exports should composite the CRT overlay: the UI overlay must be on
## (master switch) and the export-only toggle must be on.
func crt_export_allowed() -> bool:
	return crt_ui and export_crt

# ------------------------------------------------------------ fonts

## Platform fallback faces for glyphs the bundled UI font does not carry:
## emoji plus the symbol marks the preview draws for callout icons, quotes and
## list bullets (❝ ▸ ✔ ✖ …). `SystemFont.font_names` selects a SINGLE face, so
## emoji and symbols need separate entries in the fallback chain. Resolved once
## and shared so preview labels, chart labels, the window theme AND the export
## SubViewport (which only inherits the theme) all resolve the same glyphs.
var _fallback_fonts: Array[Font] = []

func fallback_fonts() -> Array[Font]:
	if not _fallback_fonts.is_empty():
		return _fallback_fonts
	# Colour emoji FIRST, loaded as a real face file. A named SystemFont can be
	# substituted by a monochrome face on some systems/exported builds, which is
	# what turned emoji black-and-white; loading the colour font by path keeps
	# its colour bitmaps (CBDT/COLR).
	for family in ["Noto Color Emoji", "Apple Color Emoji", "Segoe UI Emoji"]:
		var path := OS.get_system_font_path(family, 400, 100, false)
		if path == "":
			continue
		var face := FontFile.new()
		if face.load_dynamic_font(path) == OK:
			_fallback_fonts.append(face)
			break
	# Named fallback for platforms where the path lookup is unavailable.
	var emoji := SystemFont.new()
	emoji.font_names = PackedStringArray(["Noto Color Emoji", "Apple Color Emoji", "Segoe UI Emoji"])
	_fallback_fonts.append(emoji)
	# Symbol faces that carry ❝ ▸ ✔ ✖ (plus general punctuation). Order matters:
	# SystemFont picks the FIRST installed name, so widest coverage comes first.
	var symbols := SystemFont.new()
	symbols.font_names = PackedStringArray(["DejaVu Sans", "FreeSans", "Apple Symbols", "Segoe UI Symbol", "Noto Sans Symbols 2", "Noto Sans Symbols", "Symbola"])
	_fallback_fonts.append(symbols)
	return _fallback_fonts

## Resolved font resource for the active font family (cached per path). The
## platform fallbacks are attached to the resource itself so every consumer
## inherits them — not only the preview labels that carry explicit overrides.
func font() -> Font:
	var path: String = FONTS.get(font_name, FONTS[DEFAULT_FONT])
	if _font_cache.has(path):
		return _font_cache[path]
	var f: Font = load(path)
	if f != null:
		f.fallbacks = fallback_fonts()
	_font_cache[path] = f
	return f

## Points added to every authored font size. The default size yields 0, so the
## out-of-the-box look is byte-for-byte the old one.
func font_delta() -> int:
	return font_size - BASE_FONT_SIZE

func set_font(name: String) -> void:
	if not FONTS.has(name) or name == font_name:
		return
	font_name = name
	font_changed.emit()
	_save_settings()

func set_font_size(size: int) -> void:
	var clamped := clampi(size, MIN_FONT_SIZE, MAX_FONT_SIZE)
	if clamped == font_size:
		return
	font_size = clamped
	font_changed.emit()
	_save_settings()

# ------------------------------------------------------------ vault

func vault_abs() -> String:
	return ProjectSettings.globalize_path(vault_dir)

## Desktop: open any folder as the vault (Git/Dropbox friendly). Persists.
## Sync identity is re-bound here: the outgoing vault's phrase/peers are saved
## under its id, then the incoming folder's identity is adopted.
func set_vault_dir(path: String) -> bool:
	if not DirAccess.dir_exists_absolute(path):
		return false
	_save_vault_identity()          # persist the outgoing vault first
	vault_dir = path
	current_file = ""
	current_rel = ""
	ensure_vault_id()               # read (or mint) the new folder's id
	_load_vault_identity()          # adopt this vault's phrase + peers
	_save_settings()
	scan_notes()
	return true

# ------------------------------------------------------ vault sync identity

## True when the active vault has any paired peer (drives auto-sync + UI).
func is_vault_paired() -> bool:
	return not trusted.is_empty() or not paired_peers.is_empty()

## Read the vault's non-secret id from the vault folder ("" when none yet).
func load_vault_id() -> void:
	vault_id = ""
	var f := FileAccess.open(vault_abs() + "/" + VAULT_ID_FILE, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_DICTIONARY:
		vault_id = str(data.get("vault_id", ""))

## Persist the vault's id into the vault folder (non-secret; never synced).
func save_vault_id() -> void:
	if vault_id == "":
		return
	var f := FileAccess.open(vault_abs() + "/" + VAULT_ID_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"vault_id": vault_id}, "  "))
	f.close()

## Read the vault id, minting and persisting one if the folder has none.
func ensure_vault_id() -> void:
	load_vault_id()
	# The migrated global id only ever applies to the boot vault — consume it now
	# so a later vault switch can never reuse it.
	var legacy := _legacy_vault_id
	_legacy_vault_id = ""
	if vault_id == "":
		if dev_session:
			vault_id = "dev-" + (device_id if device_id != "" else "session")
		elif legacy != "":
			vault_id = legacy   # migrated global id becomes this vault's id
		else:
			vault_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
		save_vault_id()
	elif legacy != "" and legacy != vault_id and sync_vaults.has(legacy):
		# Interrupted upgrade: the folder already carries an id, so keep the
		# migrated pairing by moving the record onto that id.
		sync_vaults[vault_id] = sync_vaults[legacy]
		sync_vaults.erase(legacy)

## Adopt a peer's vault id (explicit pairing with an existing vault), so the
## local folder and the device-local phrase store agree on the identity.
func adopt_vault_id(new_id: String) -> void:
	if new_id == "" or new_id == vault_id:
		return
	vault_id = new_id
	save_vault_id()

## Load the active vault's phrase + trusted peers from the device-local store,
## minting a fresh phrase when this device has never seen the vault.
func _load_vault_identity() -> void:
	trusted.clear()
	paired_peers.clear()
	paired_vault_id = ""
	vault_secret = ""
	if vault_id == "":
		return
	var rec = sync_vaults.get(vault_id, {})
	if typeof(rec) != TYPE_DICTIONARY or rec.is_empty():
		vault_secret = SyncService.gen_vault_secret()  # never leaves the device
		_save_vault_identity()
		return
	vault_secret = str(rec.get("secret", ""))
	if vault_secret == "":
		vault_secret = SyncService.gen_vault_secret()
	for t in rec.get("trusted", []):
		trusted.append(String(t))
	var pp = rec.get("paired_peers", {})
	if typeof(pp) == TYPE_DICTIONARY:
		paired_peers = pp
	paired_vault_id = str(rec.get("paired_vault_id", ""))
	if paired_vault_id == "" and not paired_peers.is_empty():
		paired_vault_id = vault_id

## Write the active vault's live identity back into the device-local store.
func _save_vault_identity() -> void:
	if vault_id == "":
		return
	sync_vaults[vault_id] = {
		"secret": vault_secret,
		"trusted": trusted.duplicate(),
		"paired_peers": paired_peers.duplicate(true),
		"paired_vault_id": paired_vault_id,
	}
	_save_settings()

## Stop syncing the active vault: drop every peer but KEEP the phrase, so
## re-pairing later is a single entry. Other members are unaffected.
func unpair_vault() -> void:
	trusted.clear()
	paired_peers.clear()
	paired_vault_id = ""
	_save_vault_identity()
	sync_identity_changed.emit()

## Fork the active vault: mint a new phrase AND a new id, so this copy becomes
## its own independent vault. Existing members keep the old phrase/id.
func reset_vault_words() -> void:
	vault_secret = SyncService.gen_vault_secret()
	vault_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	trusted.clear()
	paired_peers.clear()
	paired_vault_id = ""
	save_vault_id()
	_save_vault_identity()
	sync_identity_changed.emit()

var titles := {}  # relative path -> front-matter title ("" = use filename)
var tags := {}    # relative path -> Array[String] from front-matter "tags:"
var links := {}   # relative path -> Array[String] outbound [[wiki-link]] targets
var links_ready := false  # true once scan_notes() has indexed the whole vault
# custom sort order per folder: {"folder/sub": ["note.md", …]} persisted in
# vault/.neonnotes.json (synced like a note, tiny and human-readable)
const ORDER_FILE := ".neonnotes.json"
var order := {}
var collapsed_folders: Dictionary = {}
## While true, _save_settings() is a no-op. Used by the smoke harness so test
## state can never clobber the user's real settings.
var suppress_settings_save := false

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

## Full scan: enumerate paths, then read every note for title/tags/links.
func scan_notes() -> void:
	scan_paths()
	_index_note_metadata()
	links_ready = true


## Fast boot path: enumerate note paths only (dir walk + folder-note creation +
## order). No file content is read, so the tree can render from names
## immediately; titles/tags/links follow via load_metadata_async().
## NOTE: parallel reads are counter-productive here — a WorkerThreadPool scan
## measured 2.4 s vs 0.84 s serial for 905 notes on a phone (FileAccess
## contention), so the reads stay on one thread.
func scan_paths() -> void:
	_scan_generation += 1
	notes.clear()
	titles.clear()
	tags.clear()
	links.clear()
	_scan_dir("")
	_ensure_folder_notes()
	notes.sort()
	links_ready = false
	load_order()


func _index_note_metadata() -> void:
	var vault := vault_abs()
	for n in notes:
		_apply_note_meta(n, _read_note_meta_abs(vault.path_join(n)))


## Batched, frame-yielding metadata pass used after the shell and tree are up.
## Aborts if the vault is rescanned meanwhile (generation bump).
const METADATA_BATCH := 12
var _scan_generation := 0
var _meta_scanning := false

func load_metadata_async() -> void:
	if _meta_scanning:
		return
	_meta_scanning = true
	var gen := _scan_generation
	var names := notes.duplicate()
	var vault := vault_abs()
	var i := 0
	while i < names.size():
		if gen != _scan_generation or not is_inside_tree():
			_meta_scanning = false
			return
		var end := mini(i + METADATA_BATCH, names.size())
		for k in range(i, end):
			var n: String = names[k]
			if notes.has(n):
				_apply_note_meta(n, _read_note_meta_abs(vault.path_join(n)))
		i = end
		await get_tree().process_frame
	links_ready = true
	_meta_scanning = false
	metadata_ready.emit()


func _apply_note_meta(name: String, meta: Dictionary) -> void:
	titles[name] = meta["title"]
	tags[name] = meta["tags"]
	links[name] = meta["links"]


func _read_note_meta_abs(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"title": "", "tags": [] as Array[String], "links": [] as Array[String]}
	var text := f.get_as_text()
	f.close()
	return _parse_note_meta(text)

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
				var initial := FOLDER_NOTE_TEMPLATE % [dir.get_file(), dir.get_file()]
				var title := dir.get_file()
				write_note(comp, NoteMetadata.update(NoteMetadata.body(initial), initial,
					title, [] as Array[String], Time.get_datetime_string_from_system(true, false)))
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
	return _read_note_meta_abs(vault_abs() + "/" + fname)

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
					title = title.replace("\\\"", "\"").replace("\\\\", "\\")
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
		# `\[[note]]` is escaped literal text, not a link. MarkdownParser already
		# skips it via its ESCAPE span, so the index must agree — otherwise the
		# graph and backlinks would show links the preview does not.
		if _is_escaped(text, m.get_start()):
			continue
		var target := m.get_string(1).strip_edges()
		if target != "" and not result.has(target):
			result.append(target)
	return result

## True when the character at `at` is escaped by an odd run of backslashes.
static func _is_escaped(text: String, at: int) -> bool:
	var n := 0
	var i := at - 1
	while i >= 0 and text[i] == "\\":
		n += 1
		i -= 1
	return n % 2 == 1

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
	crt_ui = bool(cf.get_value("ui", "crt_ui", crt_ui))
	font_name = String(cf.get_value("ui", "font", font_name))
	font_size = clampi(int(cf.get_value("ui", "font_size", font_size)), MIN_FONT_SIZE, MAX_FONT_SIZE)
	graph_levels = clampi(int(cf.get_value("ui", "graph_levels", graph_levels)), 1, 10)
	open_start_mode = String(cf.get_value("ui", "open_start_mode", open_start_mode))
	if open_start_mode != "last" and open_start_mode != "homepage":
		open_start_mode = "last"
	last_opened_rel = String(cf.get_value("ui", "last_opened_rel", last_opened_rel))
	if not PALETTES.has(palette_name):
		palette_name = "Synthwave"
	if not FONTS.has(font_name):
		font_name = DEFAULT_FONT
	vault_dir = cf.get_value("vault", "dir", VAULT_DIR)
	device_id = cf.get_value("sync", "device_id", "")
	sync_pin = cf.get_value("sync", "pin", "")
	# Per-vault identities (device-local). Phrase + peers live here, keyed by
	# the vault's in-folder id — never in one global settings slot.
	var vaults = cf.get_value("sync", "vaults", {})
	sync_vaults = vaults if typeof(vaults) == TYPE_DICTIONARY else {}
	# One-time migration of the old single global identity onto the vault that
	# was open; other vaults start unpaired.
	var legacy_id := String(cf.get_value("sync", "vault_id", ""))
	var legacy_secret := String(cf.get_value("sync", "vault_secret", ""))
	if sync_vaults.is_empty() and legacy_id != "" and legacy_secret != "":
		var legacy_trusted: Array = []
		for t in cf.get_value("sync", "trusted", []):
			legacy_trusted.append(String(t))
		var legacy_peers = cf.get_value("sync", "paired_peers", {})
		sync_vaults[legacy_id] = {
			"secret": legacy_secret,
			"trusted": legacy_trusted,
			"paired_peers": legacy_peers if typeof(legacy_peers) == TYPE_DICTIONARY else {},
			"paired_vault_id": String(cf.get_value("sync", "paired_vault_id", "")),
		}
		_legacy_vault_id = legacy_id

func _save_settings() -> void:
	# Smoke and ad-hoc harnesses must never overwrite the user's real settings
	# (vault selection, sync pairing, palette). _prepare_smoke_vault() sets this;
	# without it, merely opening a note inside the smoke vault persists it.
	if suppress_settings_save:
		return
	var cf := ConfigFile.new()
	cf.set_value("ui", "palette", palette_name)
	cf.set_value("export", "crt", export_crt)
	cf.set_value("ui", "crt_ui", crt_ui)
	cf.set_value("ui", "font", font_name)
	cf.set_value("ui", "font_size", font_size)
	cf.set_value("ui", "graph_levels", graph_levels)
	cf.set_value("ui", "open_start_mode", open_start_mode)
	cf.set_value("ui", "last_opened_rel", last_opened_rel)
	cf.set_value("vault", "dir", vault_dir)
	cf.set_value("sync", "device_id", device_id)
	cf.set_value("sync", "pin", sync_pin)
	cf.set_value("sync", "vaults", sync_vaults)
	cf.save(SETTINGS)

func add_trusted(id: String) -> void:
	if id != "" and not trusted.has(id):
		trusted.append(id)
		_save_vault_identity()
