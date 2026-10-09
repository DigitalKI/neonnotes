class_name MediaDialog
extends MarginContainer
## Media picker page: a scene instance inside %Content, sized and presented
## exactly like the settings/sync/new-note pages on every platform. Static
## shell lives in scenes/components/media_dialog.tscn; only the per-file
## library list is data-driven and rebuilt on every open_for().
##
## Owns the whole image-embed flow: vault library browse, device/machine
## import (SAF-backed native picker on Android), and rewriting the clicked
## `![]( )` embed in the open note. The editor, sync and flash hooks are
## injected by Main via bind(); Main only opens/closes the page.

signal close_requested

const DialogTheme := preload("res://scripts/components/dialog_theme.gd")

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
	_image_target_src = src
	var media_dir := GameManager.vault_abs().path_join("media")
	# Sync/import failures can leave empty media files behind. Clean these up
	# before building the library so broken entries are never presented.
	MediaImport.cleanup_empty_media(media_dir)
	begin(MediaImport.collect_media_images(media_dir))


## files: absolute paths of validated vault images (see _collect_media_images).
func begin(files: Array) -> void:
	for child in media_list.get_children():
		media_list.remove_child(child)
		child.queue_free()
	media_scroll.visible = not files.is_empty()
	empty_label.visible = files.is_empty()
	for path in files:
		var item := Button.new()
		item.text = path.get_file()
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.mouse_filter = Control.MOUSE_FILTER_STOP
		item.custom_minimum_size = Vector2(0, 64)
		item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.expand_icon = true
		var img := Image.load_from_file(path)
		if img:
			item.icon = ImageTexture.create_from_image(img)
		item.pressed.connect(func(): _use_local_media(path))
		media_list.add_child(item)


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
