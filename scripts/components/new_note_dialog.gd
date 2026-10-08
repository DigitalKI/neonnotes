class_name NewNoteDialog
extends MarginContainer
## New-note page: a scene instance inside %Content, sized exactly like the
## settings and sync pages (not an overlay). main.gd shows it with the shared
## page helper and connects close_requested; this component owns the note
## creation flow (placement in the custom order + editor form init).
## Layout is authored in scenes/components/new_note_dialog.tscn.

signal close_requested

@onready var name_field: LineEdit = %NameField
@onready var create_btn: Button = %CreateBtn
@onready var close_btn: Button = %CloseButton

## Injected by Main: the vault tree (placement/ordering), the note view
## (template + form init) and shell hooks (tree refresh, status flash).
var vault_tree: VaultTreeComponent
var editor: NoteEditor
var refresh_cb: Callable = func() -> void: pass
var flash_cb: Callable = func(_msg: String) -> void: pass


func bind(p_tree: VaultTreeComponent, p_editor: NoteEditor, p_refresh: Callable, p_flash: Callable) -> void:
	vault_tree = p_tree
	editor = p_editor
	refresh_cb = p_refresh
	flash_cb = p_flash


func _ready() -> void:
	visible = false
	name_field.text_submitted.connect(func(_t: String): _submit())
	create_btn.pressed.connect(_create_note)
	close_btn.pressed.connect(func(): close_requested.emit())


func _submit() -> void:
	_create_note()


## Called by the host when the page is shown.
func begin() -> void:
	name_field.text = ""
	name_field.grab_focus()


## Create the note named in the field. Placement: directly below the selected
## row. A selected note keeps its folder and the new note lands right after
## it; a selected folder takes the note as its first child; with nothing
## selected the note goes to the vault root at the end of the list.
func _create_note() -> void:
	var name := name_field.text.strip_edges().trim_suffix("/")
	if name == "" or name.contains(".."):
		return
	var fname := (name if name.ends_with(".md") else name + ".md")
	var dir := ""
	var neighbor := ""
	var first_child := false
	var sel := vault_tree.selected_item()
	if sel != null and sel != vault_tree.side_tree.get_root():
		var sel_rel := vault_tree.node_rel(sel)
		if sel_rel.ends_with(".md"):
			dir = sel_rel.get_base_dir()
			neighbor = sel_rel
		elif sel_rel != "":
			dir = sel_rel
			first_child = true
	fname = (dir + "/" if dir != "" else "") + fname
	if not FileAccess.file_exists(GameManager.vault_abs() + "/" + fname):
		var title := fname.get_file().trim_suffix(".md")
		var initial := editor.note_template(title)
		var initialized := NoteMetadata.update(NoteMetadata.body(initial), initial,
			title, [], Time.get_datetime_string_from_system(true, false))
		GameManager.write_note(fname, initialized)
		editor.begin_new_note(fname, initialized)
	GameManager.scan_notes()
	refresh_cb.call()
	vault_tree.order_new_note(fname, dir, neighbor, first_child)
	vault_tree.select_note(fname)


## Turn an unresolved wiki-link target into a new note file. Returns the
## created note's relative path, or "" if the target is not a valid note name.
func create_note_for_link(target: String) -> String:
	var rel := target.strip_edges().trim_suffix("/")
	if rel == "" or rel.contains("..") or rel.contains("\\"):
		return ""
	# Strip a leading ./ and any anchor-style suffix; keep folder components.
	while rel.begins_with("./"):
		rel = rel.substr(2)
	rel = rel.trim_suffix(".md")
	if rel == "":
		return ""
	# No folder in the target: place it next to the referencing note.
	if not rel.contains("/"):
		var cur := GameManager.current_rel
		var dir := cur.get_base_dir() if cur != "" and GameManager.notes.has(cur) else ""
		rel = (dir + "/" if dir != "" else "") + rel
	var fname := rel + ".md"
	if FileAccess.file_exists(GameManager.vault_abs() + "/" + fname):
		return fname  # Raced into existence elsewhere; just open it.
	var title := rel.get_file()
	var initial := editor.note_template(title)
	# save_source marks the form saved so a later flush of the *previous*
	# editor buffer cannot overwrite the new file's front matter.
	editor.save_source(fname, initial)
	GameManager.scan_notes()
	refresh_cb.call()
	var dir := rel.get_base_dir()
	vault_tree.order_new_note(fname, dir, "", false)
	vault_tree.select_note(fname)
	flash_cb.call("Created " + fname)
	return fname
