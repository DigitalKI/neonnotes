class_name ExportComponent
extends Node
## Export & share: builds the Export button's data-driven popup and handles
## PNG/GIF/HTML exports to vault/exports/, clipboard copies, and Android
## system sharing. The host supplies callables so this component owns no
## note-state itself:
##   doc_cb() -> Variant (parsed markdown doc, or null when unavailable)
##   dest_cb(ext: String) -> String (absolute export destination)
##   flash_cb(msg: String) -> status-bar feedback

var doc_cb: Callable
var dest_cb: Callable
var flash_cb: Callable
var get_code: Callable
## Callable() -> float logical width of the content pane (the WIDTH the
## document is actually laid out at on screen). Used as the export base width
## so exported proportions match the on-screen preview exactly; the Exporter
## then upscales uniformly (2x) on top.
var width_cb: Callable
var popup: PopupMenu
@onready var mobile_popup: PopupMenu = $Mobile
@onready var desktop_popup: PopupMenu = $Desktop

## ids shared with the ⋮ overflow menu (which routes export ids here too)
const ID_PNG := 0
const ID_GIF := 1
const ID_SHARE_PNG := 2
const ID_SHARE_GIF := 3
const ID_SHARE_MD := 4
const ID_SHARE_HTML := 5
const ID_SAVE_HTML := 6
const LOADING_DIALOG_SCENE := preload("res://scenes/components/loading_dialog.tscn")

var _loading: AcceptDialog


func _ready() -> void:
	var mobile := OS.get_name() == "Android"
	popup = mobile_popup if mobile else desktop_popup
	# Popups stay hidden until the Export button explicitly calls popup();
	# setting visible here is what caused the menu to open at launch.
	popup.id_pressed.connect(handle_action)

func get_active_popup() -> PopupMenu:
	return popup

func build_menu(_menu: PopupMenu = null) -> void:
	# Items are serialized in export_menu.tscn.
	pass



## Logical width the document is rendered at on screen. Without ui_scale or the
## sidebar this equals the content pane width; falling back to the raw physical
## width (divided by root ui_scale) keeps proportions correct in all cases.
func _export_width() -> float:
	if width_cb.is_valid():
		var w: Variant = width_cb.call()
		if w != null and float(w) > 0:
			return float(w)
	var vp: Vector2i = get_viewport().get_visible_rect().size
	var ui_scale: float = get_tree().root.content_scale_factor
	return maxf(1.0, float(vp.x) / maxf(1.0, ui_scale))
func _show_loading(message: String) -> void:
	if _loading == null or not is_instance_valid(_loading):
		_loading = LOADING_DIALOG_SCENE.instantiate()
		add_child(_loading)
	_loading.set_message(message)
	_loading.show()

func _hide_loading() -> void:
	if _loading != null and is_instance_valid(_loading):
		_loading.hide()

func handle_action(id: int) -> void:
	# CRT FX is configured exclusively from the Settings page.
	match id:
		ID_PNG, ID_GIF:  # Save PNG / GIF
			var doc: Variant = doc_cb.call()
			if doc == null:
				return
			var ext := "png" if id == ID_PNG else "gif"
			var dest: String = dest_cb.call(ext)
			if ext == "png":
				await Exporter.export_png(get_parent(), _export_width(), dest, doc)
			else:
				_show_loading("Saving GIF…")
				await Exporter.export_gif(get_parent(), _export_width(), dest, doc)
				_hide_loading()
			var saved_msg := "Saved %s: %s" % [ext.to_upper(), dest.get_file()]
			var gallery_saved := Share.save_to_gallery(dest)
			if gallery_saved and OS.get_name() != "Android":
				saved_msg += "  (also in Pictures/NeonNotes)"
			elif gallery_saved:
				saved_msg = "Saved to media library: " + dest.get_file()
			flash_cb.call(saved_msg)
		ID_SAVE_HTML:
			var html_dest: String = dest_cb.call("html") 
			if HtmlExporter.save(html_dest, MarkdownParser.parse(get_code.call())):
				flash_cb.call("Saved HTML: " + html_dest.get_file())
			else:
				flash_cb.call("✗ HTML export failed")
		ID_SHARE_PNG, ID_SHARE_GIF, ID_SHARE_MD, ID_SHARE_HTML:
			_share(id - ID_SHARE_PNG)


## kind: 0=png, 1=gif, 2=markdown text
func _share(kind: int) -> void:
	var doc: Variant = doc_cb.call()
	if doc == null:
		return
	if kind == 2:
		Share.share_text(GameManager.current_rel.get_file().trim_suffix(".md"), get_code.call())
		return
	if kind == 3:
		Share.share_text(GameManager.current_rel.get_file().trim_suffix(".md") + " (HTML)", HtmlExporter.to_html(MarkdownParser.parse(get_code.call())))
		return
	var dest: String = dest_cb.call("png" if kind == 0 else "gif")
	if kind == 0:
		await Exporter.export_png(get_parent(), _export_width(), dest, doc)
	else:
		_show_loading("Sharing GIF…")
		await Exporter.export_gif(get_parent(), _export_width(), dest, doc)
		_hide_loading()
	# PNG/GIF: images are the social-friendly format — share them directly
	Share.share_image(dest)
