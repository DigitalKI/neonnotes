class_name BacklinksCard
extends PanelContainer
## Floating backlinks card for the note view.
##
## It replaces the old panel that sat at the bottom of the vault tree: the card
## hovers over the top of the note preview/edit column, so links back to the
## open note are visible without stealing height from the tree. Structure is
## authored in scenes/components/backlinks_card.tscn; Main toggles it from the
## toolbar/⋮ menu and refreshes it whenever the open note or link index changes.
##
## The card owns no vault mutation. A row press is a navigation request: Main
## routes `backlink_selected` through the tree so the matching row is revealed
## and the note opens through the usual path.

signal backlink_selected(rel: String)

const ROW_HEIGHT := 28.0
const MAX_LIST_HEIGHT := 240.0
const CARD_MIN_WIDTH := 260.0

@onready var title_label: Label = %BacklinksTitle
@onready var close_btn: Button = %BacklinksClose
@onready var rows_scroll: ScrollContainer = %BacklinksScroll
@onready var rows_box: VBoxContainer = %BacklinksBox


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(CARD_MIN_WIDTH, 0)
	close_btn.pressed.connect(close)
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)
	GameManager.font_changed.connect(apply_theme)
	refresh()


func is_open() -> bool:
	return visible


## Toolbar/⋮ entry point: show the card, or hide it when it is already open.
func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


## Hide without touching the open note (the ✕ button and toolbar toggle).
func close() -> void:
	visible = false


## Rebuild the title and rows from the live link index. Safe to call while
## hidden: Main refreshes on metadata/note changes so the next open is current.
func refresh() -> void:
	_clear_rows()
	if GameManager.current_file == "" or GameManager.current_rel == "":
		title_label.text = "⇠ BACKLINKS"
		title_label.tooltip_text = ""
		rows_scroll.visible = false
		return

	# Same view-model as the graph focus card's Backlinks tab (resolved rels +
	# display titles + one sort order), so both surfaces always agree.
	var target := GameManager.current_rel.get_file().trim_suffix(".md")
	var links := GraphDigest.backlinks_for(GameManager.current_rel)
	title_label.text = "⇠ BACKLINKS · %d" % links.size()
	title_label.tooltip_text = "Notes that link to %s" % target
	if links.is_empty():
		title_label.text = "⇠ No notes link to “%s”" % target
		rows_scroll.visible = false
		return

	rows_scroll.visible = true
	rows_scroll.custom_minimum_size = Vector2(0,
			clampf(links.size() * ROW_HEIGHT, ROW_HEIGHT, MAX_LIST_HEIGHT))
	for entry in links:
		var rel := String(entry.get("rel", ""))
		var row := Button.new()
		row.name = "Back_" + rel.validate_filename()
		row.text = "◈ " + String(entry.get("title", rel))
		row.tooltip_text = rel
		row.flat = true
		row.focus_mode = Control.FOCUS_NONE
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		row.clip_text = true
		_style_row(row)
		row.pressed.connect(func(): backlink_selected.emit(rel))
		rows_box.add_child(row)
	rows_scroll.scroll_vertical = 0


## Rows are built dynamically, so a palette/font change must restyle the live
## rows as well as the panel (apply_theme loops them).
func _style_row(row: Button) -> void:
	var c := GameManager.palette()
	row.add_theme_color_override("font_color", c["text"])
	row.add_theme_color_override("font_hover_color", c["accent"])
	row.add_theme_color_override("font_pressed_color", c["accent"])
	row.add_theme_color_override("font_focus_color", c["accent"])
	row.add_theme_font_size_override("font_size", maxi(12, GameManager.font_size - 2))
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.12)
	hover.set_corner_radius_all(4)
	row.add_theme_stylebox_override("hover", hover)
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.22)
	row.add_theme_stylebox_override("pressed", pressed)


func _clear_rows() -> void:
	for child in rows_box.get_children():
		rows_box.remove_child(child)
		child.queue_free()


## Dark floating panel: the palette background darkened further so the card
## reads as chrome over the note, with an accent edge and a soft shadow.
func apply_theme() -> void:
	var c := GameManager.palette()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(c["bg"].darkened(0.18), 0.97)
	panel.border_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.55)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(8)
	panel.shadow_color = Color(0, 0, 0, 0.55)
	panel.shadow_size = 8
	add_theme_stylebox_override("panel", panel)

	title_label.add_theme_color_override("font_color", c["accent2"])
	title_label.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 4))
	close_btn.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.6))
	close_btn.add_theme_color_override("font_hover_color", c["accent"])
	close_btn.add_theme_color_override("font_pressed_color", c["accent"])
	close_btn.add_theme_font_size_override("font_size", maxi(12, GameManager.font_size - 2))
	for row in rows_box.get_children():
		if row is Button:
			_style_row(row)
	_style_scrollbar()


func _style_scrollbar() -> void:
	var c := GameManager.palette()
	var vsb := rows_scroll.get_v_scroll_bar()
	vsb.custom_minimum_size = Vector2(14, 0)
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.40)
	grabber.set_corner_radius_all(6)
	grabber.set_content_margin_all(5)
	vsb.add_theme_stylebox_override("grabber", grabber)
	var hot := grabber.duplicate() as StyleBoxFlat
	hot.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.85)
	vsb.add_theme_stylebox_override("grabber_highlight", hot)
	vsb.add_theme_stylebox_override("grabber_pressed", hot)
