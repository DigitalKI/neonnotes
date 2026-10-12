class_name GraphFocusCard
extends PanelContainer
## Focus card for the graph map: "what is inside this node" at a glance.
##
## Display-only for now (no actions). Structure is authored in
## scenes/components/graph_focus_card.tscn; this script renders a view-model
## built by `GraphDigest` and places the card for the current form factor:
##  - desktop        → semi-transparent panel floating at the top-right
##  - phone landscape→ right rail, full height
##  - phone portrait → bottom sheet (1/3 of the screen)
##
## The card owns no vault logic: Main resolves the model (note vs folder
## aggregate) and calls `show_model()`; a digest arriving later re-renders.

const CARD_MIN_W := 260.0
const CARD_MAX_W := 380.0
const CARD_MIN_H := 120.0
const SCREEN_MARGIN := 12.0
const PORTRAIT_FRACTION := 1.0 / 3.0
signal child_selected(rel: String)   # a row in a folder's child list
signal tag_selected(tag: String)     # a tag chip: filter the vault by it
signal links_opened                  # the links header button: show them all

## Bounded lists: the card must stay readable rather than exhaustive. Links
## do not list here at all — the header button opens the full links page, so
## the excerpt keeps the space.
const MAX_TAGS := 16
const MAX_CHILDREN_VISIBLE := 60
const CHILD_ROW_H := 19.0
const CHILDREN_MAX_H := 220.0

@onready var column: VBoxContainer = %CardColumn
@onready var kind_label: Label = %CardKind
@onready var title_label: Label = %CardTitle
@onready var tags_chips: HFlowContainer = %CardTags
@onready var tabs_row: HBoxContainer = %CardTabs
@onready var tab_content: Button = %TabContent
@onready var tab_children: Button = %TabChildren
@onready var links_row: HBoxContainer = %LinksRow
@onready var links_header: Label = %CardLinksHeader
@onready var links_btn: Button = %CardLinksBtn
@onready var children_header: Label = %CardChildrenHeader
@onready var children_scroll: ScrollContainer = %CardChildrenScroll
@onready var children_box: VBoxContainer = %CardChildren
@onready var excerpt_label: Label = %CardExcerpt
@onready var meta_label: Label = %CardMeta

var _model := {}
## Folder cards have two tabs: the note's own content first, the child list
## second (memory: "notes that have child notes should show the note content,
## and on a second tab the list of child nodes").
var _folder_tab := "content"
## Injected by Main: re-place the card for the current form factor. The shell
## owns the form-factor decision (phone portrait/landscape vs desktop); the
## card never guesses it, so `show_model()` asks instead of laying out itself.
var relayout_cb: Callable = func() -> void: pass

func _ready() -> void:
	visible = false
	clip_contents = true
	links_btn.pressed.connect(func(): links_opened.emit())
	tab_content.pressed.connect(func(): _set_tab("content"))
	tab_children.pressed.connect(func(): _set_tab("children"))
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)
	GameManager.font_changed.connect(apply_theme)

# ------------------------------------------------------------------ theming

## Semi-transparent neon panel: the graph has to stay partly visible behind it.
func apply_theme() -> void:
	var c := GameManager.palette()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.80)
	panel.border_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.55)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(5)
	add_theme_stylebox_override("panel", panel)
	kind_label.add_theme_color_override("font_color", c["accent2"])
	title_label.add_theme_color_override("font_color", c["accent"])
	links_header.add_theme_color_override("font_color", Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.75))
	links_btn.add_theme_color_override("font_color", c["accent"])
	# Tabs: the active one is disabled (it IS the view) but bright; the other
	# stays pressable and dim.
	for tab in [tab_content, tab_children]:
		tab.add_theme_color_override("font_color", c["accent2"])
		tab.add_theme_color_override("font_disabled_color", c["accent"])
		tab.add_theme_font_size_override("font_size", 12)
	children_header.add_theme_color_override("font_color", Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.75))
	excerpt_label.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.85))
	meta_label.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
	# Header labels are small captions; the title carries the hierarchy.
	for caption in [links_header, children_header]:
		caption.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 4))
	meta_label.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
	excerpt_label.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 2))
	_style_children_scrollbar()
	if not _model.is_empty():
		_render()

## Touch-friendly grabber, matching the preview/tree scrollbars.
func _style_children_scrollbar() -> void:
	var vsb := children_scroll.get_v_scroll_bar()
	vsb.custom_minimum_size = Vector2(14, 0)
	var c := GameManager.palette()
	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.40)
	grabber.set_corner_radius_all(6)
	grabber.set_content_margin_all(5)
	vsb.add_theme_stylebox_override("grabber", grabber)
	var hot := grabber.duplicate()
	hot.bg_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.85)
	vsb.add_theme_stylebox_override("grabber_highlight", hot)
	vsb.add_theme_stylebox_override("grabber_pressed", hot)

# ------------------------------------------------------------------ content

func show_model(model: Dictionary) -> void:
	_model = model
	_folder_tab = "content"
	if _model.is_empty():
		close()
		return
	_render()
	visible = true
	relayout_cb.call()
	# Container minimum sizes settle a frame after the rows are built; re-place
	# the card once they have, so a stale minimum cannot inflate the panel.
	relayout_cb.call_deferred()

func close() -> void:
	_model = {}
	visible = false

func is_open() -> bool:
	return visible

func model() -> Dictionary:
	return _model

func _render() -> void:
	var is_folder: bool = String(_model.get("kind", "note")) == "folder"
	kind_label.text = "◆" if is_folder else "●"
	title_label.text = String(_model.get("title", ""))
	title_label.tooltip_text = String(_model.get("rel", ""))

	_render_tags(_model.get("tags", []) as Array)
	var show_body := true
	if is_folder:
		_render_children(_model.get("children", []) as Array)
		links_row.visible = false
		tabs_row.visible = true
		tab_content.disabled = _folder_tab == "content"
		tab_children.disabled = _folder_tab == "children"
		show_body = _folder_tab == "content"
		children_header.visible = not show_body
		children_scroll.visible = not show_body
	else:
		_render_links()
		tabs_row.visible = false
		children_header.visible = false
		children_scroll.visible = false
		_clear(children_box)

	excerpt_label.text = String(_model.get("excerpt", ""))
	excerpt_label.visible = show_body and excerpt_label.text != ""
	meta_label.text = _meta_text()
	meta_label.visible = show_body and meta_label.text != ""

func _meta_text() -> String:
	var parts: Array[String] = []
	var created := GraphDigest.human_date(String(_model.get("created", "")))
	var updated := String(_model.get("updated", ""))
	if created != "":
		parts.append("created " + created)
	var age := GraphDigest.relative_age(updated)
	if age == "":
		var stamp := GraphDigest.human_date(updated)
		if stamp != "":
			parts.append("edited " + stamp)
	elif age == "today":
		parts.append("edited today")
	else:
		parts.append("edited " + age)
	var words := int(_model.get("words", 0))
	if words > 0:
		parts.append("%d words" % words)
	var open_items := int(_model.get("checklist_open", 0))
	if open_items > 0:
		parts.append("%d open" % open_items)
	var images := int(_model.get("images", 0))
	if images > 0:
		parts.append("%d img" % images)
	if not bool(_model.get("detail_ready", true)):
		parts.append("reading…")
	return " · ".join(parts)

func _render_tags(tags: Array) -> void:
	_clear(tags_chips)
	var shown := mini(tags.size(), MAX_TAGS)
	var c := GameManager.palette()
	for i in shown:
		var chip := Button.new()
		chip.text = "◆ " + str(tags[i])
		chip.focus_mode = Control.FOCUS_NONE
		chip.custom_minimum_size = Vector2(0, 26)
		chip.tooltip_text = "Filter by #" + str(tags[i])
		var tag := str(tags[i])
		chip.pressed.connect(func(): tag_selected.emit(tag))
		chip.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
		tags_chips.add_child(chip)
	if tags.size() > shown:
		var more := Label.new()
		more.text = "+%d" % (tags.size() - shown)
		more.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
		tags_chips.add_child(more)

## Outgoing links: one compact header row with a count; the button opens the
## full links page so the excerpt keeps the card's space.
func _render_links() -> void:
	var links: Array = _model.get("links", [])
	links_row.visible = not links.is_empty()
	links_header.text = "⇢ LINKS · %d" % links.size()

func _render_children(children: Array) -> void:
	_clear(children_box)
	children_header.visible = true
	children_header.text = "▣ %d NOTES" % children.size()
	children_scroll.visible = true
	children_scroll.scroll_vertical = 0
	# Size the viewport to the list (bounded): a 2-child folder should not
	# reserve a 90 px empty window, while a 60-child one stays scrollable.
	var rows := minf(children.size(), MAX_CHILDREN_VISIBLE)
	children_scroll.custom_minimum_size = Vector2(0,
		minf(rows * CHILD_ROW_H + 6.0, CHILDREN_MAX_H))
	var c := GameManager.palette()
	# Rows are Buttons so the child list doubles as navigation: a press asks
	# Main to focus that node on the map (or open it when it is off-page).
	var shown := mini(children.size(), MAX_CHILDREN_VISIBLE)
	for i in shown:
		var entry: Dictionary = children[i]
		var row := Button.new()
		row.text = "· " + String(entry.get("title", ""))
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.85))
		row.tooltip_text = String(entry.get("rel", ""))
		var rel := String(entry.get("rel", ""))
		row.pressed.connect(func(): child_selected.emit(rel))
		children_box.add_child(row)
	if children.size() > shown:
		children_box.add_child(_more_label(children.size() - shown))

## Passive overflow note (children list is scrollable, so it stays a label).
func _more_label(count: int) -> Label:
	var more := Label.new()
	more.text = "… +%d more" % count
	var c := GameManager.palette()
	more.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
	more.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
	return more

## Switch the folder card's tab and re-render in place.
func _set_tab(tab: String) -> void:
	if _folder_tab == tab:
		return
	_folder_tab = tab
	if not _model.is_empty():
		_render()

func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

# ------------------------------------------------------------------- layout

## Place the card for the current form factor. `vp` is the shell size and
## `top_inset` keeps the desktop panel clear of the toolbar.
func apply_layout(vp: Vector2 = Vector2.ZERO, mobile := false, portrait := false, top_inset := 44.0) -> void:
	if vp == Vector2.ZERO:
		vp = get_parent_area_size()

	var m := SCREEN_MARGIN
	if mobile and portrait:
		var h: float = _sheet_height(vp)
		anchor_left = 0.0; anchor_right = 1.0
		anchor_top = 1.0; anchor_bottom = 1.0
		offset_left = m; offset_right = -m
		offset_top = -(h + m); offset_bottom = -m
	elif mobile:
		var w: float = _rail_width(vp)
		anchor_left = 1.0; anchor_right = 1.0
		anchor_top = 0.0; anchor_bottom = 1.0
		offset_left = -(w + m); offset_right = -m
		offset_top = m; offset_bottom = -m
	else:
		var w: float = clampf(vp.x * 0.28, CARD_MIN_W, CARD_MAX_W)
		anchor_left = 1.0; anchor_right = 1.0
		anchor_top = 0.0; anchor_bottom = 0.0
		offset_left = -(w + m); offset_right = -m
		offset_top = top_inset + m
		offset_bottom = top_inset + m + maxf(CARD_MIN_H, minf(vp.y - top_inset - 2.0 * m, get_combined_minimum_size().y))

## Screen space the card takes away from the map. Mobile only: the desktop
## panel floats in a corner with room to spare, but a phone rail / bottom sheet
## would otherwise hide the neighbourhood the camera just framed.
func covered_inset(vp: Vector2, mobile: bool, portrait: bool) -> Dictionary:
	if not mobile or vp == Vector2.ZERO:
		return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if portrait:
		return {"left": 0.0, "top": 0.0, "right": 0.0,
			"bottom": _sheet_height(vp) + SCREEN_MARGIN}
	return {"left": 0.0, "top": 0.0, "right": _rail_width(vp) + SCREEN_MARGIN, "bottom": 0.0}

func _sheet_height(vp: Vector2) -> float:
	return maxf(CARD_MIN_H, vp.y * PORTRAIT_FRACTION)

func _rail_width(vp: Vector2) -> float:
	return clampf(vp.x * 0.42, 240.0, 420.0)
