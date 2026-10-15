class_name CapturePage
extends MarginContainer
## Capture page: put a link or a piece of text into the vault Inbox without
## leaving the app — and the landing surface an Android share intent will feed
## once that lands. A scene instance inside %Content like every other page;
## Main routes it and owns the tree refresh via the `captured` signal.
##
## Static shell lives in scenes/components/capture_page.tscn.

signal close_requested
signal captured(rel: String)

const DialogTheme := preload("res://scripts/components/dialog_theme.gd")

@onready var name_field: LineEdit = %NameField
@onready var field: TextEdit = %CaptureField
@onready var paste_btn: Button = %PasteBtn
@onready var image_btn: Button = %ImageBtn
@onready var capture_btn: Button = %CaptureBtn
@onready var close_btn: Button = %CloseButton
@onready var hint: Label = %Hint

## Injected by Main: the status flash.
var flash_cb: Callable = func(_msg: String) -> void: pass

## The one real Window left (it must browse files), like MediaDialog's picker.
var image_dialog: FileDialog


func bind(p_flash: Callable) -> void:
	flash_cb = p_flash


func _ready() -> void:
	visible = false
	paste_btn.pressed.connect(_paste)
	image_btn.pressed.connect(_choose_image)
	capture_btn.pressed.connect(_capture)
	close_btn.pressed.connect(func(): close_requested.emit())


## Called by the host when the page is shown.
func begin() -> void:
	field.text = ""
	name_field.text = ""
	hint.text = "Paste a link, or type anything. Saved to Inbox/."
	field.grab_focus()


func _paste() -> void:
	var clip := DisplayServer.clipboard_get().strip_edges()
	if clip == "":
		flash_cb.call("✗ Clipboard is empty")
		return
	field.text = clip
	hint.text = "Pasted from the clipboard — press Capture."


func _capture() -> void:
	var text := field.text.strip_edges()
	if text == "":
		flash_cb.call("✗ Nothing to capture")
		return
	var opts := {}
	var title := name_field.text.strip_edges()
	if title != "":
		opts["title"] = title
	# capture_link falls back to text for non-URLs but records `source:` for
	# real links, so one entry point covers both.
	var rel := Capture.capture_link(text, opts)
	if rel == "":
		flash_cb.call("✗ Capture failed")
		return
	flash_cb.call("📥 Captured → " + rel)
	captured.emit(rel)


func _choose_image() -> void:
	if image_dialog == null:
		image_dialog = FileDialog.new()
		image_dialog.name = "CaptureImageDialog"
		image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		image_dialog.access = FileDialog.ACCESS_FILESYSTEM
		# Android's sandbox cannot enumerate shared storage through the desktop
		# picker; the native SAF picker returns a readable path/URI instead.
		if OS.get_name() == "Android":
			image_dialog.use_native_dialog = true
		image_dialog.title = "CAPTURE IMAGE"
		image_dialog.filters = ["*.png,*.PNG,*.jpg,*.JPG,*.jpeg,*.JPEG,*.webp,*.WEBP,*.gif,*.GIF ; IMAGE FILES"]
		image_dialog.file_selected.connect(_on_image_selected)
		DialogTheme.apply(image_dialog)
		add_child(image_dialog)
	var vp := get_viewport().get_visible_rect().size
	image_dialog.popup_centered(Vector2i(
		int(min(700.0, max(300.0, vp.x * 0.92))),
		int(min(500.0, max(280.0, vp.y * 0.78)))))


func _on_image_selected(path: String) -> void:
	var rel := Capture.capture_image(path, {"flash_cb": flash_cb})
	if rel == "":
		flash_cb.call("✗ Could not capture image")
		return
	flash_cb.call("📥 Captured image → " + rel)
	captured.emit(rel)


## Settings' palette changes must re-theme the file dialog too.
func apply_theme() -> void:
	if image_dialog != null:
		DialogTheme.apply(image_dialog)
