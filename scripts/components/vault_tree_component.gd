class_name VaultTreeComponent
extends PanelContainer
## SidePanel subscene root + vault-tree controller: tag chips, tree building
## (folder-as-note merge), drag & drop, ordering (vault/.neonnotes.json),
## move/rename with wiki-link rewrite, and empty-folder pruning.
## Note-state stays in GameManager; the host injects save_cb (_flush_save)
## and flash_cb (status feedback) and connects the signals below.

signal note_requested(fname: String)
signal delete_requested

@onready var side_tree: Tree = %SideTree
@onready var tree_delete_btn: Button = %TreeDeleteBtn
@onready var backlinks_panel: PanelContainer = %BacklinksPanel
@onready var backlinks_box: VBoxContainer = %BacklinksBox
@onready var config_btn: Button = %ConfigBtn
@onready var search: LineEdit = %Search

var save_cb: Callable
var flash_cb: Callable
var moved_cb: Callable
var _tree_menu := PopupMenu.new()
var _press_pos := Vector2.ZERO
var _press_item: TreeItem
var _press_item_toggle := false
var _touch_src_path := ""
var _is_touch_dragging := false
var _root_homepage := ""
var _search_timer := Timer.new()
var _search_thread: Thread
var _search_cancel := false
var _search_generation := 0
var _search_query := ""
var _search_results: Array = []
var _search_snippets: Dictionary = {}
var _search_shutting_down := false
const MOBILE_DRAG_HOLD_SECONDS := 3.0
const TREE_TAP_MAX_DISTANCE := 16.0
const TREE_DRAG_START_DISTANCE := 10.0
var _mobile_touch_candidate := false
var _mobile_hold_ready := false
var _mobile_hold_timer := Timer.new()
var _search_cleanup_scheduled := false

## Wire behavior once the scene nodes are ready. The host connects
## palette_btn/vault_btn/sync_btn/tree_delete_btn signals itself.

# ---------------------------------------------- backlinks panel (moved from main.gd)

func toggle_backlinks() -> void:
	backlinks_panel.visible = not backlinks_panel.visible
	if backlinks_panel.visible:
		refresh_backlinks()

func refresh_backlinks() -> void:
	for c in backlinks_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.name = "BacklinksTitle"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	backlinks_box.add_child(title)
	if GameManager.current_file == "":
		title.text = "Open a note to see backlinks"
		return
	var target := GameManager.current_rel.get_file().trim_suffix(".md")
	var links := WikiLinks.backlinks(target)
	if links.is_empty():
		title.text = "⇠ No notes link to “%s”" % target
		return
	title.text = "⇠ %d note(s) link here" % links.size()
	for f in links:
		var b := Button.new()
		b.name = "Back_" + f.validate_filename()
		b.text = "◈ " + f.trim_suffix(".md")
		b.pressed.connect(select_note.bind(f))
		backlinks_box.add_child(b)

func build() -> void:
	_search_timer.one_shot = true
	_search_timer.wait_time = 2.0
	_search_timer.timeout.connect(_start_search)
	add_child(_search_timer)
	_mobile_hold_timer.one_shot = true
	_mobile_hold_timer.wait_time = MOBILE_DRAG_HOLD_SECONDS
	_mobile_hold_timer.timeout.connect(_activate_mobile_drag)
	add_child(_mobile_hold_timer)
	search.text_changed.connect(_on_search_changed)
	side_tree.item_activated.connect(_on_tree_selected)
	# Match the editor's touch-friendly scrollbar width. Tree exposes its
	# internal scrollbar as a child rather than via get_v_scroll_bar().
	for child in side_tree.get_children():
		if child is VScrollBar:
			child.custom_minimum_size = Vector2(14, 0)
	# NeonNotes marks state with the palette (selection fill, accent drop tint),
	# so the default theme's grey-white decorations are noise. In particular
	# `cursor`/`cursor_unfocused` is a 2 px WHITE RECTANGLE drawn on the focused
	# row — it read as a stray line on whatever node the pointer touched.
	# `selected`/`selected_focus` are deliberately kept: that is the only
	# selection feedback left.
	for sb_name in ["hovered", "hovered_dimmed", "hovered_selected",
			"hovered_selected_focus", "cursor", "cursor_unfocused", "focus"]:
		side_tree.add_theme_stylebox_override(sb_name, StyleBoxEmpty.new())
	# The artefact users report as a "white line under the hovered node with a
	# vertical line up to its parent" is Godot's native DROP MARKER, not the
	# guide/highlight lines: `drop_position_color` defaults to PURE WHITE
	# (1,1,1,1) and `drop_on_item_color` is white too, and the Tree draws them
	# for any row it considers a drop target — i.e. on plain hover, because
	# DROP_MODE_ON_ITEM|DROP_MODE_INBETWEEN is enabled for reordering.
	# Verified by painting each Tree colour red in a fresh run: only
	# drop_position_color recolours that line. The app draws its own
	# palette-accent drop hint (_mark_drop_hint), so the native marker is noise.
	for c_name in ["drop_position_color", "drop_on_item_color"]:
		side_tree.add_theme_color_override(c_name, Color(0, 0, 0, 0))
	# Ancestry-chain highlight (underline + vertical guide run) and the hovered
	# row's text brightening: same family of artefacts, also removed.
	for c_name in ["parent_hl_line_color", "children_hl_line_color"]:
		side_tree.add_theme_color_override(c_name, Color(0, 0, 0, 0))
	var font_c: Color = side_tree.get_theme_color("font_color")
	for c_name in ["font_hovered_color", "font_hovered_dimmed_color", "font_hovered_selected_color"]:
		side_tree.add_theme_color_override(c_name, font_c)
	side_tree.item_collapsed.connect(_on_item_collapsed)
	# Documented Tree property: a drag hovering over a collapsed folder must
	# NOT unfold it. Folder expansion is arrow-only in NeonNotes.
	side_tree.enable_drag_unfolding = false
	# Ensure the vault root always has a non-deletable homepage note.
	_root_homepage = "_homepage.md"
	if not FileAccess.file_exists(GameManager.vault_abs().path_join(_root_homepage)):
		GameManager.write_note(_root_homepage, "# Home\n\nWelcome to NeonNotes.\n")
	# Trigger note opening on mouse/touch RELEASE so dragging a row never
	# accidentally opens a note or closes the mobile sidebar drawer.
	side_tree.gui_input.connect(_on_tree_gui_input)
	# drag notes/folders between folders + reorder rows (registered once; see
	# refresh() and the Android repeat-drag gotcha in PROJECT_MEMORY.md)
	_tree_menu.add_item("🗑 Delete…", 1)
	_tree_menu.id_pressed.connect(func(id: int):
		if id == 1:
			delete_requested.emit())

func _on_tree_gui_input(ev: InputEvent) -> void:
	if _tree_ignores_raw_touch() and (ev is InputEventScreenTouch or ev is InputEventScreenDrag):
		return
	if _is_primary_tree_press_release(ev):
		if ev.pressed:
			_handle_tree_press(ev.position)
		else:
			_handle_tree_release(ev.position)
		return
	if ev is InputEventMouseMotion:
		if ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_handle_tree_drag_motion(ev.position, true)
		return
	if ev is InputEventScreenDrag:
		_handle_tree_drag_motion(ev.position, true)
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
		var it := side_tree.get_item_at_position(side_tree.get_local_mouse_position())
		if _tree_item_has_metadata(it):
			it.select(0)
			_tree_menu.popup(Rect2i(get_global_mouse_position(), Vector2i.ZERO))

func _is_primary_tree_press_release(ev: InputEvent) -> bool:
	return (ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT) \
			or ev is InputEventScreenTouch

func _tree_ignores_raw_touch() -> bool:
	return OS.get_name() == "Android"

func _handle_tree_press(pos: Vector2) -> void:
	_press_pos = pos
	_press_item = side_tree.get_item_at_position(pos)
	_press_item_toggle = _press_item != null and _is_tree_toggle_click(_press_item, pos)
	_is_touch_dragging = false
	_drag_just_happened = false
	_mobile_touch_candidate = false
	_mobile_hold_ready = false
	_mobile_hold_timer.stop()
	_touch_src_path = _tree_item_drag_path(_press_item)
	if _touch_src_path != "" and OS.get_name() == "Android":
		_mobile_touch_candidate = true
		_mobile_hold_timer.start()

func _handle_tree_release(pos: Vector2) -> void:
	_mobile_hold_timer.stop()
	if _is_touch_dragging or _drag_just_happened:
		_finish_tree_drag(pos)
	elif not _mobile_hold_ready and pos.distance_to(_press_pos) < TREE_TAP_MAX_DISTANCE:
		_activate_pressed_tree_item()
	_reset_tree_touch_state()

func _handle_tree_drag_motion(pos: Vector2, consume_event: bool) -> void:
	if _touch_src_path == "" or not _mobile_hold_ready:
		return
	if consume_event:
		side_tree.accept_event()
	if pos.distance_to(_press_pos) <= TREE_DRAG_START_DISTANCE:
		return
	_is_touch_dragging = true
	var target_item := side_tree.get_item_at_position(pos)
	var section := _custom_drop_section(target_item, pos)
	_mark_drop_hint(target_item, section)

func _finish_tree_drag(pos: Vector2) -> void:
	if _touch_src_path == "":
		return
	var target_item := side_tree.get_item_at_position(pos)
	var section := _custom_drop_section(target_item, pos)
	_perform_drop(_touch_src_path, target_item, section)

func _activate_pressed_tree_item() -> void:
	var item := _press_item
	if not _tree_item_has_metadata(item):
		return
	# The left folding arrow is a tree control, not a note activation.
	if _press_item_toggle:
		side_tree.accept_event()
		return
	side_tree.set_selected(item, 0)
	_open_tree_item(item)

func _reset_tree_touch_state() -> void:
	_is_touch_dragging = false
	_drag_just_happened = false
	_touch_src_path = ""
	_mobile_touch_candidate = false
	_mobile_hold_ready = false
	_press_item = null
	_press_item_toggle = false

## Populate the palette selector (source of truth: GameManager.PALETTES).
func build_palette() -> void:
	pass

## Active tag filter ("" = show all). Set by the tag chips above the tree.
var active_tag := ""


func note_visible(n: String) -> bool:
	return active_tag == "" or GameManager.tags.get(n, []).has(active_tag)

func visible_notes() -> Array[String]:
	var out: Array[String] = []
	var search_active := _search_query.length() >= 3
	for n in GameManager.notes:
		if note_visible(n) and (not search_active or _search_results.has(n)):
			out.append(n)
	if search_active:
		out.sort_custom(func(a: String, b: String) -> bool:
			return _search_results.find(a) < _search_results.find(b))
	return out

## Row of tag chips above the tree: click to filter, click again to clear.
func _build_tag_bar() -> void:
	var bar := side_tree.get_parent().get_node_or_null("TagBar") as HFlowContainer
	if bar == null:
		bar = HFlowContainer.new()
		bar.name = "TagBar"
		var vbox := side_tree.get_parent()
		vbox.add_child(bar)
		vbox.move_child(bar, side_tree.get_index())
	var all := GameManager.all_tags()
	bar.visible = all.size() > 0
	for c in bar.get_children():
		c.queue_free()
	for tag in all:
		var b := Button.new()
		b.text = ("● " if tag == active_tag else "#") + tag
		b.toggle_mode = false
		b.pressed.connect(func():
			active_tag = "" if active_tag == tag else tag
			refresh())
		bar.add_child(b)
	if all.size() > 0:
		var clear := Button.new()
		clear.text = "✕"
		clear.visible = active_tag != ""
		clear.pressed.connect(func():
			active_tag = ""
			refresh())
		bar.add_child(clear)

func _on_search_changed(value: String) -> void:
	_search_query = value.strip_edges()
	_search_generation += 1
	_search_cancel = true
	_retire_search_thread()
	if _search_thread != null:
		# Keep ownership until the worker exits and can be joined safely.
		_schedule_search_cleanup()
	else:
		_search_timer.start()
	if _search_query.length() < 3:
		_search_results = []
		refresh()

func _start_search() -> void:
	if _search_shutting_down or _search_query.length() < 3:
		return
	if _search_thread != null:
		_schedule_search_cleanup()
		return
	_search_cancel = false
	var generation := _search_generation
	var query := _search_query.to_lower()
	var snapshot: Array = []
	for n in GameManager.notes:
		snapshot.append({"name": n, "title": String(GameManager.titles.get(n, "")), "text": GameManager.read_note(n)})
	_search_thread = Thread.new()
	_search_thread.start(_search_worker.bind(snapshot, query, generation))

func _activate_mobile_drag() -> void:
	if _mobile_touch_candidate and _touch_src_path != "":
		_mobile_hold_ready = true
		flash_cb.call("DRAG READY — move to place")

func _retire_search_thread() -> void:
	if _search_thread != null and _search_thread.is_started():
		_search_cancel = true

func _schedule_search_cleanup() -> void:
	if _search_cleanup_scheduled:
		return
	_search_cleanup_scheduled = true
	call_deferred("_poll_search_cleanup")

func _poll_search_cleanup() -> void:
	_search_cleanup_scheduled = false
	if _search_thread == null:
		if not _search_shutting_down and _search_query.length() >= 3:
			_search_timer.start()
		return
	if _search_thread.is_alive():
		_schedule_search_cleanup()
		return
	_search_thread.wait_to_finish()
	_search_thread = null
	if not _search_shutting_down and _search_query.length() >= 3:
		_search_timer.start()

func _exit_tree() -> void:
	_search_shutting_down = true
	_search_generation += 1
	_search_cancel = true
	_retire_search_thread()
	# Joining is required before the node is freed: the worker captures this
	# instance through its cancellation/generation checks. Search workers only
	# read their immutable snapshot and stop between files, so this is bounded.
	if _search_thread != null:
		_search_thread.wait_to_finish()
		_search_thread = null

func _search_worker(snapshot: Array, query: String, generation: int) -> void:
	var title_hits: Array = []
	var content_hits: Array = []
	for item in snapshot:
		if _search_cancel or generation != _search_generation:
			return
		var title: String = String(item.title).to_lower()
		var haystack: String = (String(item.title) + "\n" + String(item.text)).to_lower()
		var matches_all := true
		for word in query.split(" ", false):
			if not haystack.contains(word):
				matches_all = false
				break
		if not matches_all:
			continue
		if title.contains(query):
			title_hits.append(item.name)
		else:
			content_hits.append(item.name)
	_search_results = title_hits + content_hits
	call_deferred("_apply_search_results", generation)

func _apply_search_results(generation: int) -> void:
	if _search_shutting_down or generation != _search_generation or _search_query.length() < 3:
		return
	refresh()

func refresh() -> void:
	side_tree.clear()
	side_tree.hide_root = false
	_build_tag_bar()
	# Drag notes/folders between folders + reorder rows. Tree rows are never
	# expanded by hover; folder expansion is handled only by the arrow click.
	side_tree.set_drop_mode_flags(Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN)
	# set_drag_forwarding() is persistent; re-registering it after every refresh
	# can invalidate the active drag on Android.
	if not _tree_drag_forwarding_set:
		side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
		_tree_drag_forwarding_set = true
	var root := side_tree.create_item()
	root.set_text(0, "Vault")
	root.set_metadata(0, "")
	root.disable_folding = true
	root.collapsed = false
	root.set_selectable(0, true)
	if _search_query.length() >= 3:
		for n in visible_notes():
			_add_search_result(n)
		return
	# build folder hierarchy from relative paths
	var folders := {}
	# pass 1: folders first, so a note + folder sharing a name merge into one
	# node (e.g. "medic.md" + "medic/" -> one row that opens the note)
	for n in visible_notes():
		var parts := n.split("/")
		var parent: TreeItem = root
		var path := ""
		for i in parts.size() - 1:
			path = (path + "/" if path != "" else "") + parts[i]
			if not folders.has(path):
				var it := side_tree.create_item(parent)
				var companion: String = path + ".md"
				if GameManager.notes.has(companion):
					var ft: String = GameManager.titles.get(companion, "")
					if ft == "":
						ft = parts[i]
					it.set_text(0, "◈ " + ft)
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, companion)  # clicking opens the note
				else:
					it.set_text(0, "▸ " + parts[i])
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, path)  # plain folder
				it.set_selectable(0, true)
				# Existing saved state wins; new folders start collapsed.
				it.collapsed = bool(GameManager.collapsed_folders.get(path, true))
				folders[path] = it
			parent = folders[path]
	# pass 2: note leaves in custom order (skipping those merged into folder rows)
	for dir in folders.keys():
		for n in ordered_notes(dir):
			var parent: TreeItem = folders[dir]
			if n == dir + ".md":
				continue  # already represented by the merged folder row
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue  # already represented by a subfolder row
			_add_note_leaf(parent, n)
	for n in ordered_notes(""):
		if not n.contains("/"):
			# The protected homepage is opened through the Vault root row.
			if n == _root_homepage:
				continue
			# A companion note such as `help.md` is represented by the merged
			# `help/` folder row above; never show it a second time at root.
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue
			_add_note_leaf(root, n)
func _add_search_result(n: String) -> void:
	var base := n.get_file().trim_suffix(".md")
	var label: String = GameManager.titles.get(n, base)
	if label == "":
		label = base
	var leaf := side_tree.create_item(side_tree.get_root())
	leaf.set_text(0, "◈ " + label)
	var snippet: String = String(_search_snippets.get(n, ""))
	leaf.set_tooltip_text(0, n + (" — " + snippet if snippet != "" else ""))
	leaf.set_metadata(0, n)

func _add_note_leaf(parent: TreeItem, n: String) -> void:
	var base := n.get_file().trim_suffix(".md")
	var label: String = GameManager.titles.get(n, base)
	if label == "":
		label = base
	var leaf := side_tree.create_item(parent)
	leaf.set_text(0, "◈ " + label)
	leaf.set_tooltip_text(0, base)
	leaf.set_metadata(0, n)

## Notes inside `dir`, custom order first, then alphabetical.
func ordered_notes(dir: String) -> Array[String]:
	var lst: Array[String] = []
	for n in GameManager.notes:
		if n.get_base_dir() == dir and note_visible(n):
			lst.append(n)
	var want: Array = GameManager.order.get(dir, [])
	lst.sort_custom(func(a: String, b: String) -> bool:
		var ia := want.find(a)
		var ib := want.find(b)
		if ia == -1 and ib == -1:
			return a < b
		if ia == -1:
			return false
		if ib == -1:
			return true
		return ia < ib)
	return lst

# ---------------------------------------------- tree drag & drop (v3)

func _tree_get_drag(at_position: Vector2) -> Variant:
	var it := side_tree.get_item_at_position(at_position)
	var meta := _tree_item_drag_path(it)
	if meta == "":
		return null
	_drag_just_happened = true
	_is_touch_dragging = true

	var preview := MarginContainer.new()
	var label := Label.new()
	label.text = " 📄 " + it.get_text(0) + " "
	label.add_theme_color_override("font_color", GameManager.color("accent"))
	preview.add_child(label)
	set_drag_preview(preview)

	return {"type": "neonnotes_move", "path": meta, "label": it.get_text(0)}

## True between a tree drag and its release — lets the release handler select
## the note (otherwise a drag gesture swallows the click).
var _drag_just_happened := false
var _tree_drag_forwarding_set := false

## Calculates the drop section for `it` at mouse position `at_position`.
## Widens the "MOVE INTO" (section 0) target zone for folders and notes so
## creating parent/children structures is easy to hit on touch and desktop.
func _custom_drop_section(it: TreeItem, at_position: Vector2) -> int:
	if it == null or it == side_tree.get_root():
		return 0  # dropping anywhere on root moves into vault root
	var rect := side_tree.get_item_area_rect(it)
	if rect.size.y <= 0.0:
		return side_tree.get_drop_section_at_position(at_position)
	var rel_y := at_position.y - rect.position.y
	var ratio := clampf(rel_y / rect.size.y, 0.0, 1.0)

	var meta := str(it.get_metadata(0))
	var is_folder_row := not meta.ends_with(".md")
	if not is_folder_row and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		is_folder_row = true

	if is_folder_row:
		# Folders are primary containers: 70% middle zone for MOVE INTO
		if ratio < 0.15:
			return -1
		elif ratio > 0.85:
			return 1
		else:
			return 0
	else:
		# Standalone notes: 60% middle zone for MOVE INTO (create folder container)
		if ratio < 0.20:
			return -1
		elif ratio > 0.80:
			return 1
		else:
			return 0

func _tree_can_drop(at_position: Vector2, data: Variant) -> bool:
	var ok: bool = typeof(data) == TYPE_DICTIONARY and data.get("type", "") == "neonnotes_move"
	if not ok:
		_clear_drop_hint()
		return false
	var target := side_tree.get_item_at_position(at_position)
	_mark_drop_hint(target, _custom_drop_section(target, at_position))
	return true

## Android has no native drop highlight — tint the hovered row and show the
## exact target operation in the status bar.
var _drop_hint: TreeItem
var _drop_section := 0

func _mark_drop_hint(it: TreeItem, section: int = 0) -> void:
	if _drop_hint == it and _drop_section == section:
		return
	if _drop_hint != null and is_instance_valid(_drop_hint):
		_drop_hint.clear_custom_bg_color(0)
	_drop_hint = it
	_drop_section = section
	if it == null:
		flash_cb.call("Ready")
		return
	var c := GameManager.color("accent")
	# inside = solid bright row; above/below = thinner directional tint
	# Inside is a brighter palette accent; before/after use a darker tint.
	var tint := c.lightened(0.22) if section == 0 else c.darkened(0.28)
	var alpha := 0.62 if section == 0 else 0.42
	it.set_custom_bg_color(0, Color(tint.r, tint.g, tint.b, alpha))
	var target := str(it.get_metadata(0)).trim_suffix(".md")
	if target == "":
		target = "Vault"
	if section == 0:
		flash_cb.call("MOVE INTO › " + target)
	elif section < 0:
		flash_cb.call("PLACE ABOVE › " + target)
	else:
		flash_cb.call("PLACE BELOW › " + target)

func _clear_drop_hint() -> void:
	_mark_drop_hint(null, 0)
	_drop_section = 0

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_clear_drop_hint()

func _perform_drop(src: String, it: TreeItem, section: int) -> void:
	if src == "":
		_clear_drop_hint()
		return
	# target folder: the parent folder of the row under the cursor
	var target_dir := ""
	if it != null and it.get_metadata(0) != null:
		var meta := str(it.get_metadata(0))
		var is_folder_row := not meta.ends_with(".md")
		# merged folder+note row: metadata is the .md but the folder exists
		if not is_folder_row and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
			is_folder_row = true
			meta = meta.trim_suffix(".md")
		if section == 0:
			if is_folder_row:
				target_dir = meta  # drop "on" a folder → into it
			else:
				# Dropping onto a standalone note turns it into a container.
				# The note becomes `name/` + `name.md` automatically.
				target_dir = meta.trim_suffix(".md")
		else:
			target_dir = meta.get_base_dir() if meta.contains("/") else ""
	save_cb.call()
	var new_rel := move_path(src, target_dir)
	_clear_drop_hint()
	if new_rel == "":
		flash_cb.call("✗ Move failed")
		return
	# reorder within the same folder when dropped between rows
	if section != 0 and it != null and it.get_metadata(0) != null:
		var dst_meta := str(it.get_metadata(0))
		var dst_dir := dst_meta.get_base_dir() if dst_meta.contains("/") else ""
		if dst_dir == (new_rel.get_base_dir() if new_rel.contains("/") else ""):
			_apply_order(new_rel, dst_dir, dst_meta, section < 0)
	# (The index was already remapped inside move_path, before the rewrites.)
	# Only the moved path's own ancestor chain can have become empty.
	prune_empty_ancestors(src)
	refresh()
	# reopen if the open note was the one moved/renamed
	if GameManager.current_rel == "" and new_rel.ends_with(".md"):
		select_note(new_rel)
	flash_cb.call("Moved → " + new_rel)

func _tree_drop(at_position: Vector2, data: Variant) -> void:
	var src := str(data.get("path", ""))
	var it := side_tree.get_item_at_position(at_position)
	var section := _custom_drop_section(it, at_position)
	_perform_drop(src, it, section)

## Remove directories emptied by moving `rel` away, walking up only its own
## ancestor chain (the full-vault prune below is far more expensive).
func prune_empty_ancestors(rel: String) -> void:
	var dir := rel.get_base_dir()
	while dir != "":
		var abs := GameManager.vault_abs().path_join(dir)
		if not DirAccess.dir_exists_absolute(abs):
			dir = dir.get_base_dir()
			continue
		if not DirAccess.get_directories_at(abs).is_empty() \
				or not DirAccess.get_files_at(abs).is_empty():
			return
		DirAccess.remove_absolute(abs)
		dir = dir.get_base_dir()

## Remove now-empty folders (bottom-up) so restructuring leaves no leftovers.
func prune_empty_dirs() -> void:
	var changed := true
	while changed:
		changed = false
		for d in _all_dirs(""):
			var abs := GameManager.vault_abs().path_join(d)
			if DirAccess.get_directories_at(abs).is_empty() and DirAccess.get_files_at(abs).is_empty():
				if DirAccess.remove_absolute(abs) == OK:
					changed = true

func _all_dirs(rel: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(GameManager.vault_abs() + ("/" + rel if rel != "" else ""))
	if d == null:
		return out
	for f in d.get_directories():
		if f.begins_with("."):
			continue
		var child := rel + ("/" if rel != "" else "") + f
		out.append(child)
		out.append_array(_all_dirs(child))
	return out

## Insert `rel` into the folder's order list next to `neighbor`.
func _apply_order(rel: String, dir: String, neighbor: String, before: bool) -> void:
	var lst: Array = GameManager.order.get(dir, [])
	# seed with current visual order
	if lst.is_empty():
		lst = ordered_notes(dir)
	lst.erase(rel)
	var idx := lst.find(neighbor)
	if idx == -1:
		lst.append(rel)
	else:
		lst.insert(idx if before else idx + 1, rel)
	GameManager.order[dir] = lst
	GameManager.save_order()

## Move a note or folder (vault-relative) into `dst_dir` ("" = vault root).
## Auto-renames on collision. Returns the new relative path ("" on failure).
func move_path(src_rel: String, dst_dir: String) -> String:
	var old_paths := _paths_under(src_rel)
	var vault := GameManager.vault_abs()
	var src := vault.path_join(src_rel)
	if not FileAccess.file_exists(src) and not DirAccess.dir_exists_absolute(src):
		return ""
	# never drop a folder into itself or one of its children
	if not src_rel.ends_with(".md") and (dst_dir == src_rel or dst_dir.begins_with(src_rel + "/")):
		return ""
	# companion note should not be moved into its own companion folder
	if src_rel.ends_with(".md") and dst_dir == src_rel.trim_suffix(".md"):
		return src_rel

	var dst := vault if dst_dir == "" else vault.path_join(dst_dir)
	DirAccess.make_dir_recursive_absolute(dst)
	var base := src_rel.get_file()
	var target := dst.path_join(base)
	if src == target:
		return src_rel

	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var stem := base.trim_suffix(".md")
		var ext := ".md" if base.ends_with(".md") else ""
		var i := 2
		while FileAccess.file_exists(dst.path_join("%s-%d%s" % [stem, i, ext])) \
				or DirAccess.dir_exists_absolute(dst.path_join("%s-%d" % [stem, i])):
			i += 1
		target = dst.path_join("%s-%d%s" % [stem, i, ext])
	if DirAccess.rename_absolute(src, target) != OK:
		return ""
	var new_rel := target.trim_prefix(vault + "/")
	# Remap the in-memory index (paths only; titles/tags/links travel with the
	# files) before the link rewrites, so those rewrites pick their candidates
	# and write back at the paths the files now have — never the old ones.
	GameManager.remap_moved(src_rel, new_rel)
	if src_rel.ends_with(".md"):
		_rewrite_links(src_rel, new_rel)
	else:
		# moving a FOLDER: take its companion note along and rewrite every
		# [[old/sub/note]] link that pointed inside it
		var companion := src_rel + ".md"
		# companion follows the final folder name, including collision suffixes
		var comp_target := target.get_base_dir().path_join(target.get_file() + ".md")
		if FileAccess.file_exists(vault.path_join(companion)) and not FileAccess.file_exists(comp_target):
			DirAccess.rename_absolute(vault.path_join(companion), comp_target)
		_rewrite_folder_links(src_rel, new_rel)
	# keep the open note consistent if it was the one moved
	if GameManager.current_rel == src_rel:
		GameManager.current_file = target
		GameManager.current_rel = new_rel
	if moved_cb.is_valid():
		# Report both the old and the new paths: the old ones become tombstones,
		# the new ones must clear any tombstone peers still hold for them (a
		# folder moved back onto a previously deleted path).
		var new_paths: Array[String] = []
		for p in old_paths:
			new_paths.append(PathRemap.moved(p, src_rel, new_rel))
		moved_cb.call(old_paths, new_paths)
	return new_rel

func _paths_under(rel: String) -> Array[String]:
	var out: Array[String] = []
	var vault := GameManager.vault_abs()
	var base := vault.path_join(rel)
	if FileAccess.file_exists(base):
		out.append(rel)
		return out
	if not DirAccess.dir_exists_absolute(base):
		return out
	for f in DirAccess.get_files_at(base):
		out.append(rel.path_join(f))
	for d in DirAccess.get_directories_at(base):
		out.append_array(_paths_under(rel.path_join(d)))
	var companion := rel + ".md"
	if FileAccess.file_exists(vault.path_join(companion)):
		out.append(companion)
	return out

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_links(old_rel: String, new_rel: String) -> void:
	var old_noext := old_rel.trim_suffix(".md")
	var new_noext := new_rel.trim_suffix(".md")
	# Compile each pattern ONCE per move: the previous code re-created the
	# identical RegEx for every candidate note, which is pure CPU on the UI
	# thread and grows with vault size.
	var rules: Array = [[
		RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + _re_escape(old_noext) + "(\\]\\]|\\|)"),
		"[[" + new_noext + "$1",
	]]
	var old_base := old_noext.get_file()
	var new_base := new_noext.get_file()
	if old_base != new_base:
		rules.append([
			RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + _re_escape(old_base) + "(\\]\\]|\\|)"),
			"[[" + new_base + "$1",
		])
	# Only notes whose indexed links can match this move are rewritten.
	for n in _move_rewrite_candidates(old_rel):
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		if t.contains("[["):
			for rule in rules:
				t = (rule[0] as RegEx).sub(t, rule[1], true)
		if t != orig:
			GameManager.write_note(n, t)

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_folder_links(old_dir: String, new_dir: String) -> void:
	# Compiled once per move (was: once per candidate note).
	var folder_re := RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + _re_escape(old_dir) + "/")
	# Only notes whose indexed links can match the old folder prefix.
	for n in _move_rewrite_candidates(old_dir):
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		if t.contains("[["):
			t = folder_re.sub(t, "[[" + new_dir + "/", true)
		if t != orig:
			GameManager.write_note(n, t)

## Notes that could contain a link to the moved path. Backed by the link
## index so a drop touches only affected notes; falls back to a full path
## walk when the index is not built (e.g. a vault that has not been scanned).
func _move_rewrite_candidates(old_prefix: String) -> Array[String]:
	if not GameManager.links_ready:
		return GameManager.list_note_paths()
	return GameManager.notes_linking_to(old_prefix)

## Escape regex metacharacters (Godot has no String.regex_escape).
func _re_escape(s: String) -> String:
	var out := ""
	for ch in s:
		if "\\.^$|?*+()[]{}".contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out

func _tree_item_has_metadata(item: TreeItem) -> bool:
	return item != null and is_instance_valid(item) and item.get_metadata(0) != null

func _tree_item_note_path(item: TreeItem) -> String:
	if item == null:
		return ""
	if item == side_tree.get_root():
		return _root_homepage
	if not _tree_item_has_metadata(item):
		return ""
	var meta := str(item.get_metadata(0))
	if meta.ends_with(".md") and GameManager.notes.has(meta):
		return meta
	return ""

func _tree_item_drag_path(item: TreeItem) -> String:
	if item == null or item == side_tree.get_root() or not _tree_item_has_metadata(item):
		return ""
	var meta := str(item.get_metadata(0))
	if meta == "":
		return ""
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		return meta.trim_suffix(".md")
	return meta

func _is_tree_toggle_click(item: TreeItem, pos: Vector2) -> bool:
	if item == side_tree.get_root() or not item.collapsed and item.get_child_count() == 0:
		return false
	var area := side_tree.get_item_area_rect(item)
	# Godot's folding arrow is in the leading ~24px of the row.
	return pos.x <= area.position.x + 28.0

func _on_item_collapsed(item: TreeItem) -> void:
	var rel := node_rel(item)
	if rel != "":
		GameManager.collapsed_folders[rel] = item.collapsed
		GameManager.save_order()

func _on_tree_selected() -> void:
	_open_tree_item(side_tree.get_selected())

func _open_tree_item(item: TreeItem) -> void:
	var fname := _tree_item_note_path(item)
	if fname != "":
		note_requested.emit(fname)

func select_note(fname: String, open_note := true) -> void:
	# find matching leaf in the tree
	var stack: Array[TreeItem] = [side_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_metadata(0) == fname:
			side_tree.scroll_to_item(it, false)
			side_tree.set_selected(it, 0)
			if open_note:
				_open_tree_item(it)
			return
		for c in it.get_children():
			stack.append(c)


## The currently selected tree row (or null).
func selected_item() -> TreeItem:
	return side_tree.get_selected()

## Resolve a tree row's path: a merged folder+note row (`x.md` metadata while
## folder `x` exists) counts as the FOLDER `x`.
func node_rel(it: TreeItem) -> String:
	var rel := _tree_item_drag_path(it)
	return "" if rel == _root_homepage else rel

## Determine if a path (folder or companion note) has child items in the vault.
func has_children(rel: String) -> bool:
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var abs_folder := vault.path_join(folder_rel)
	if not DirAccess.dir_exists_absolute(abs_folder):
		return false
	for d in DirAccess.get_directories_at(abs_folder):
		if not d.begins_with("."):
			return true
	for f in DirAccess.get_files_at(abs_folder):
		if not f.begins_with("."):
			return true
	return false
