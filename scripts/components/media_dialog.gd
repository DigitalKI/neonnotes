class_name MediaDialog
extends MarginContainer
## Media page: a scene instance inside %Content, sized and presented
## exactly like the settings/sync/new-note pages on every platform. Static
## shell lives in scenes/components/media_dialog.tscn; the per-file library
## list is data-driven and rebuilt on every open.
##
## One page, two modes. The **embed picker** (`open_for`, opened from a
## clicked `![]( )` embed) targets the clicked embed: picking a row rewrites
## it and saves. The **media library** (`open_library`, opened from the ⋮
## menu) is management mode: every row shows which notes reference the file,
## expands to a clickable "used in" list, and can delete the file (permanent,
## confirmed). Both modes share the same row builder and import button.

signal close_requested
## A "used in" row was activated in library mode: the shell closes the page
## and opens the note through the vault tree (reveal + select).
signal note_requested(rel: String)

const DialogTheme := preload("res://scripts/components/dialog_theme.gd")

@onready var heading: Label = %Heading
@onready var media_scroll: ScrollContainer = %MediaScroll
@onready var media_list: VBoxContainer = %MediaList
@onready var empty_label: Label = %EmptyLabel
@onready var device_button: Button = %DeviceButton
@onready var close_btn: Button = %CloseButton

## Injected by Main: the note view (embed rewrite + save + re-render), the
## sync service hook and the status flash.
var editor: NoteEditor
var sync_note_saved_cb: Callable = func(_rel: String) -> void: pass
var flash_cb: Callable = func(_msg: String) -> void: pass

## The `src` of the embed that was clicked (empty = the `![]( )` placeholder).
var _image_target_src := ""
## False = embed picker (rows rewrite the clicked embed); true = media
## library (rows expand usage + offer delete). Only the picker rewrites md.
var _library_mode := false

## The only real Window left (it must browse files); every other surface is a
## page that inherits the shell styling directly.
var image_dialog: FileDialog


func bind(p_editor: NoteEditor, p_sync_note_saved: Callable, p_flash: Callable) -> void:
	editor = p_editor
	sync_note_saved_cb = p_sync_note_saved
	flash_cb = p_flash


func _ready() -> void:
	visible = false
	device_button.pressed.connect(_choose_device_image)
	close_btn.pressed.connect(func(): close_requested.emit())


## An image embed was clicked in the preview: choose an existing vault asset
## or import a new image from the device/machine. Main has already opened the
## page (page routing is the shell's job).
func open_for(src: String) -> void:
	_library_mode = false
	_image_target_src = src
	heading.text = "🖼 CHOOSE MEDIA SOURCE"
	var media_dir := GameManager.vault_abs().path_join("media")
	# Sync/import failures can leave empty media files behind. Clean these up
	# before building the library so broken entries are never presented.
	MediaImport.cleanup_empty_media(media_dir)
	begin(MediaImport.collect_media_images(media_dir))


## ⋮ → Media Library: management mode. Same listing, but rows carry a usage
## count with an expandable "used in" list and a delete button; the name
## button toggles the usage list instead of rewriting an embed.
func open_library() -> void:
	_library_mode = true
	_image_target_src = ""
	heading.text = "🖼 MEDIA LIBRARY"
	var media_dir := GameManager.vault_abs().path_join("media")
	MediaImport.cleanup_empty_media(media_dir)
	begin(MediaImport.collect_media_images(media_dir))


## files: absolute paths of validated vault images (see _collect_media_images).
func begin(files: Array) -> void:
	for child in media_list.get_children():
		media_list.remove_child(child)
		child.queue_free()
	media_scroll.visible = not files.is_empty()
	empty_label.visible = files.is_empty()
	if files.is_empty():
		return
	var notes: Array[String] = []
	notes.assign(GameManager.notes)
	var media_files: Array[String] = []
	media_files.assign(files)
	var usage := MediaImport.build_usage_map(GameManager.vault_abs(), notes, media_files)
	for path in media_files:
		media_list.add_child(_row(path, usage.get(path.get_file(), []) as Array))


## One media file row: [thumbnail/name button][usage label][🗑], plus an
## expandable "used in" list in library mode. The name button targets the
## clicked embed in picker mode, toggles the usage list in library mode.
## Carries `media_path`/`media_name` metadata so harnesses can find rows.
func _row(path: String, refs: Array) -> VBoxContainer:
	var name := path.get_file()
	var box := VBoxContainer.new()
	box.set_meta("media_path", path)
	box.set_meta("media_name", name)

	# Built before the toggle lambda below, which flips its visibility.
	var detail := VBoxContainer.new()
	detail.visible = false

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	var item := Button.new()
	item.text = name
	# One row per file: a long, unbreakable name must ellipsize instead of
	# widening the row (and with it the whole page).
	item.clip_text = true
	item.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	item.tooltip_text = name
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.mouse_filter = Control.MOUSE_FILTER_STOP
	item.custom_minimum_size = Vector2(0, 64)
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.expand_icon = true
	var img := Image.load_from_file(path)
	if img:
		item.icon = ImageTexture.create_from_image(img)
	if _library_mode:
		item.toggle_mode = true
		item.toggled.connect(func(on: bool): detail.visible = on)
	else:
		item.pressed.connect(func(): _use_local_media(path))
	row.add_child(item)

	var usage_label := Label.new()
	var tip := "Used in:\n"
	for rel in refs:
		tip += "• %s\n" % rel
	if refs.is_empty():
		tip = "Not referenced by any note."
	usage_label.text = "unused" if refs.is_empty() else "%d note%s" % [refs.size(), "" if refs.size() == 1 else "s"]
	usage_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	usage_label.tooltip_text = tip
	row.add_child(usage_label)

	var del := Button.new()
	del.text = "🗑"
	del.tooltip_text = "Delete %s…" % name
	del.pressed.connect(func(): _confirm_delete(path, refs))
	row.add_child(del)

	if _library_mode:
		if refs.is_empty():
			var none := Label.new()
			none.text = "· not used in any note"
			detail.add_child(none)
		for rel in refs:
			var nb := Button.new()
			nb.text = "📄 " + rel
			nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
			nb.clip_text = true
			nb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			nb.tooltip_text = rel
			nb.flat = true
			nb.pressed.connect(func(): note_requested.emit(rel))
			detail.add_child(nb)
		box.add_child(detail)
	return box


## The Settings page's font changes must re-theme the file dialog too.
func apply_theme() -> void:
	if image_dialog != null:
		DialogTheme.apply(image_dialog)


## An existing vault asset was picked: point the clicked embed at it; the
## markdown is updated + saved.
func _use_local_media(path: String) -> void:
	var t := editor.code_edit.text
	var pattern := "!\\[[^\\]]*\\]\\(\\s*" + ("" if _image_target_src == "" else TextUtils.re_escape(_image_target_src)) + "\\s*\\)"
	var m := RegEx.create_from_string(pattern).search(t)
	if m == null:
		flash_cb.call("✗ Could not find image embed")
		return
	var rel := "media/" + path.get_file()
	_replace_embed(t, m, rel)
	var media_source := editor.compose_note_source()
	editor.save_source(GameManager.current_rel, media_source)
	flash_cb.call("✓ Saved " + GameManager.current_rel)
	sync_note_saved_cb.call(GameManager.current_rel)
	editor.render_preview()
	# Selection consumed the embed: return to the note like the close button.
	close_requested.emit()


func _replace_embed(t: String, m: RegExMatch, rel: String) -> void:
	editor.code_edit.text = t.substr(0, m.get_start()) + "![](" + rel + ")" + t.substr(m.get_end())


func _save_and_render() -> void:
	var media_source := editor.compose_note_source()
	editor.save_source(GameManager.current_rel, media_source)
	flash_cb.call("✓ Saved " + GameManager.current_rel)
	sync_note_saved_cb.call(GameManager.current_rel)
	if not editor.source_mode:
		editor.render_preview()


## Permanent media deletion, after confirmation. Notes that still embed the
## file keep their text: the preview falls back to the "click to choose"
## placeholder, which is exactly the pre-delete picker entry point.
func _confirm_delete(path: String, refs: Array) -> void:
	var name := path.get_file()
	var dlg := ConfirmationDialog.new()
	dlg.title = "DELETE MEDIA"
	var msg := "Permanently delete %s?\n\nThis cannot be undone." % name
	if not refs.is_empty():
		msg += "\n\nIt is still referenced by %d note%s; those embeds will show a placeholder." % [refs.size(), "" if refs.size() == 1 else "s"]
	dlg.dialog_text = msg
	dlg.ok_button_text = "🗑 Delete"
	dlg.get_cancel_button().text = "Cancel"
	DialogTheme.apply(dlg)
	add_child(dlg)
	dlg.confirmed.connect(func():
		_delete_media(path, refs)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _delete_media(path: String, refs: Array) -> void:
	var name := path.get_file()
	if DirAccess.remove_absolute(path) != OK:
		flash_cb.call("✗ Could not delete " + name)
		return
	if refs.is_empty():
		flash_cb.call("🗑 Deleted " + name)
	else:
		flash_cb.call("🗑 Deleted %s — %d note%s still reference it" % [name, refs.size(), "" if refs.size() == 1 else "s"])
	_refresh_rows()


## Rebuild the listing after a delete/import, keeping the current mode.
func _refresh_rows() -> void:
	var media_dir := GameManager.vault_abs().path_join("media")
	MediaImport.cleanup_empty_media(media_dir)
	begin(MediaImport.collect_media_images(media_dir))


func _choose_device_image() -> void:
	if image_dialog == null:
		image_dialog = FileDialog.new()
		image_dialog.name = "ImageDialog"
		image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		image_dialog.access = FileDialog.ACCESS_FILESYSTEM
		# Android's sandbox cannot enumerate shared storage through Godot's
		# desktop picker. The native picker uses the Storage Access Framework and
		# returns a readable, temporary file path without broad storage access.
		if OS.get_name() == "Android":
			image_dialog.use_native_dialog = true
		image_dialog.title = "CHOOSE IMAGE"
		# Include upper-case suffixes explicitly: Android/Desktop pickers may apply
		# these filters case-sensitively (camera files commonly use .JPG).
		image_dialog.filters = ["*.png,*.PNG,*.jpg,*.JPG,*.jpeg,*.JPEG,*.webp,*.WEBP,*.gif,*.GIF ; IMAGE FILES"]
		image_dialog.file_selected.connect(_on_image_selected)
		DialogTheme.apply(image_dialog)
		add_child(image_dialog)
	var viewport_size := get_viewport().get_visible_rect().size
	var dialog_size := Vector2i(
		int(min(700.0, max(300.0, viewport_size.x * 0.92))),
		int(min(500.0, max(280.0, viewport_size.y * 0.78))))
	image_dialog.popup_centered(dialog_size)


func _on_image_selected(path: String) -> void:
	var media_dir := GameManager.vault_abs() + "/media"
	DirAccess.make_dir_recursive_absolute(media_dir)
	# Debug aid: some SAF-backed pickers pass a content:// URI whose last
	# segment is an internal id rather than the display name. Log the exact
	# path so we know whether this is the folder-dependent case.
	print("[NN image] selected path='%s' file='%s'" % [path, path.get_file()])
	# Naming + import live in MediaImport (scripts/common/media_import.gd); the
	# embed rewrite + note save below stay with the editor state.
	var is_content_uri := path.begins_with("content://")
	var dest := MediaImport.media_dest_for(media_dir, path.get_file(), is_content_uri)
	var wrote := MediaImport.import_image(path, dest, flash_cb)
	if not wrote:
		flash_cb.call("✗ Could not import image")
		return
	var rel := "media/" + dest.get_file()
	# Library mode imports without an embed target: the new file just joins
	# the refreshed listing; the markdown stays untouched.
	if _library_mode:
		flash_cb.call("🖼 Imported " + rel)
		_refresh_rows()
		return
	# update the embed that was clicked: empty-src form `![…]( )` when the
	# placeholder was used, otherwise the exact src (tolerating whitespace)
	var t := editor.code_edit.text
	var re: RegEx
	if _image_target_src == "":
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*\\)")
	else:
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*" + TextUtils.re_escape(_image_target_src) + "\\s*\\)")
	var m := re.search(t)
	# The slash menu inserts `![]( )`; match that exact empty placeholder,
	# including its optional whitespace, before falling back to another image.
	if _image_target_src == "":
		var empty_embed := RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*\\)")
		m = empty_embed.search(t)
	if m == null:
		var fallback := RegEx.create_from_string("(?m)^[^\\n]*!\\[[^\\]]*\\]\\([^\\n]*\\)[^\\n]*$")
		m = fallback.search(t)
	if m:
		_replace_embed(t, m, rel)
		print("[NN image] embed updated rel='%s'" % rel)
	else:
		flash_cb.call("✗ Could not find image embed")
		print("[NN image] embed not found; target='%s' rel='%s'" % [_image_target_src, rel])
		return
	# save directly — the click comes from preview mode where the editor is
	# hidden and flush() would bail out
	if GameManager.current_rel != "":
		_save_and_render()
	flash_cb.call("🖼 " + rel)
