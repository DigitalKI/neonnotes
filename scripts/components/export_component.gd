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

## ids shared with the ⋮ overflow menu (which routes export ids here too)
const ID_PNG := 0
const ID_GIF := 1
const ID_COPY_MD := 2
const ID_COPY_HTML := 3
const ID_SAVE_HTML := 4
const ID_SHARE_PNG := 5
const ID_SHARE_GIF := 6
const ID_SHARE_MD := 7


func build_menu(menu: PopupMenu) -> void:
	menu.add_item("🖼 Save PNG", ID_PNG)
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


func handle_action(id: int) -> void:
	match id:
		ID_PNG, ID_GIF:  # Save PNG / GIF
			var doc: Variant = doc_cb.call()
			if doc == null:
				return
			var ext := "png" if id == ID_PNG else "gif"
			var dest: String = dest_cb.call(ext)
			if ext == "png":
				await Exporter.export_png(get_parent(), get_viewport().get_visible_rect().size.x, dest, doc)
			else:
				await Exporter.export_gif(get_parent(), get_viewport().get_visible_rect().size.x, dest, doc)
			if OS.get_name() == "Android" and Share.save_to_gallery(dest):
				flash_cb.call("Saved to media library: " + dest.get_file())
			else:
				flash_cb.call("Saved %s: %s" % [ext.to_upper(), dest.get_file()])
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
		await Exporter.export_png(get_parent(), get_viewport().get_visible_rect().size.x, dest, doc)
	else:
		await Exporter.export_gif(get_parent(), get_viewport().get_visible_rect().size.x, dest, doc)
	# PNG/GIF: images are the social-friendly format — share them directly
	Share.share_image(dest)