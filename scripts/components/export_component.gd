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

## ids shared with the ⋮ overflow menu (which routes export ids here too)
const ID_PNG := 0
const ID_JPG := 1
const ID_GIF := 2
const ID_COPY_MD := 3
const ID_COPY_HTML := 4
const ID_SAVE_HTML := 5
const ID_SHARE_PNG := 6
const ID_SHARE_GIF := 7
const ID_SHARE_MD := 8
const ID_CRT := 50


func build_menu(menu: PopupMenu) -> void:
	menu.add_separator()
	menu.add_item("🖥 CRT FX on export", ID_CRT)
	menu.set_item_as_checkable(menu.get_item_index(ID_CRT), true)
	menu.set_item_checked(menu.get_item_index(ID_CRT), GameManager.export_crt)
	menu.add_separator()
	menu.add_item("🖼 Save PNG (2× lossless)", ID_PNG)
	menu.add_item("📷 Save JPEG (2× quality 95%)", ID_JPG)
	menu.add_item("🎞 Save GIF", ID_GIF)
	menu.add_separator()
	menu.add_item("📤 Share PNG", ID_SHARE_PNG)
	menu.add_item("📤 Share GIF", ID_SHARE_GIF)
	menu.add_item("📤 Share Markdown", ID_SHARE_MD)
	menu.add_separator()
	menu.add_item("Copy Markdown", ID_COPY_MD)
	menu.add_item("Copy HTML", ID_COPY_HTML)
	menu.add_item("Save HTML…", ID_SAVE_HTML)
	if OS.get_name() != "Android":
		# On desktop, "share" falls back to clipboard/file manager; keep the
		# menu lean there.
		menu.remove_item(ID_SHARE_PNG)
		menu.remove_item(ID_SHARE_GIF)
		menu.remove_item(ID_SHARE_MD)



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
func handle_action(id: int) -> void:
	# CRT export toggle (also reachable from the ⋮ overflow fallback which
	# routes unknown ids here). Flip the persisted setting and its checkmark.
	if id == ID_CRT:
		var menu: PopupMenu = null
		if get_parent() is Control:
			for child in get_parent().get_children():
				if child is MenuButton and child.get_popup() != null:
					menu = child.get_popup()
		var on := not GameManager.export_crt
		GameManager.set_export_crt(on)
		if menu != null and menu.get_item_index(ID_CRT) != -1:
			menu.set_item_checked(menu.get_item_index(ID_CRT), on)
		flash_cb.call("CRT FX on export: " + ("ON" if on else "OFF"))
		return
	match id:
		ID_PNG, ID_JPG, ID_GIF:  # Save PNG / JPEG / GIF
			var doc: Variant = doc_cb.call()
			if doc == null:
				return
			var ext := "png" if id == ID_PNG else ("jpg" if id == ID_JPG else "gif")
			var dest: String = dest_cb.call(ext)
			if ext == "png":
				await Exporter.export_png(get_parent(), _export_width(), dest, doc)
			elif ext == "jpg":
				await Exporter.export_jpg(get_parent(), _export_width(), dest, doc)
			else:
				await Exporter.export_gif(get_parent(), _export_width(), dest, doc)
			var saved_msg := "Saved %s: %s" % [ext.to_upper(), dest.get_file()]
			var gallery_saved := Share.save_to_gallery(dest)
			if gallery_saved and OS.get_name() != "Android":
				saved_msg += "  (also in Pictures/NeonNotes)"
			elif gallery_saved:
				saved_msg = "Saved to media library: " + dest.get_file()
			flash_cb.call(saved_msg)
		ID_COPY_MD:
			DisplayServer.clipboard_set(get_code.call())
			flash_cb.call("Markdown copied to clipboard")
		ID_COPY_HTML:
			DisplayServer.clipboard_set(HtmlExporter.to_html(MarkdownParser.parse(get_code.call())))
			flash_cb.call("HTML copied to clipboard")
		ID_SAVE_HTML:
			var dest: String = dest_cb.call("html")
			if HtmlExporter.save(dest, MarkdownParser.parse(get_code.call())):
				flash_cb.call("Saved HTML: " + dest.get_file())
			else:
				flash_cb.call("✗ HTML export failed")
		ID_SHARE_PNG, ID_SHARE_GIF, ID_SHARE_MD:
			_share(id - ID_SHARE_PNG)


## kind: 0=png, 1=gif, 2=markdown text
func _share(kind: int) -> void:
	var doc: Variant = doc_cb.call()
	if doc == null:
		return
	if kind == 2:
		Share.share_text(GameManager.current_rel.get_file().trim_suffix(".md"), get_code.call())
		return
	var dest: String = dest_cb.call("png" if kind == 0 else "gif")
	if kind == 0:
		await Exporter.export_png(get_parent(), _export_width(), dest, doc)
	else:
		await Exporter.export_gif(get_parent(), _export_width(), dest, doc)
	# PNG/GIF: images are the social-friendly format — share them directly
	Share.share_image(dest)