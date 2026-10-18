class_name GraphFocusCard
extends PanelContainer
## Focus card for the graph map: "what is inside this node" at a glance.
##
## Structure is authored in scenes/components/graph_focus_card.tscn; this
## script renders a view-model built by `GraphDigest` and places the card for
## the current form factor:
##  - desktop        → semi-transparent panel floating at the top-right
##  - phone landscape→ right rail, full height
##  - phone portrait → bottom sheet (1/3 of the screen)
##
## The card owns no vault logic: Main resolves the model (note vs folder
## aggregate) and calls `show_model()`; a digest arriving later re-renders.
## Its affordances are all signals: the title opens the note, tag chips filter,
## child rows navigate, and the links header opens the links page.

const CARD_MIN_W := 260.0
const CARD_MAX_W := 380.0
const CARD_MIN_H := 120.0
const SCREEN_MARGIN := 12.0
const PORTRAIT_FRACTION := 1.0 / 3.0
signal child_selected(rel: String)      # a row in a folder's child list
signal backlink_selected(rel: String)   # a row in the backlinks list
signal tag_selected(tag: String)        # a tag chip: filter the vault by it
signal links_opened                     # the links header button: show them all
signal title_opened(rel: String)        # the title: open that note (like menu Open)

## Bounded lists: the card must stay readable rather than exhaustive. Links
## do not list here at all — the header button opens the full links page, so
## the excerpt keeps the space.
const MAX_TAGS := 16
const MAX_CHILDREN_VISIBLE := 60
const CHILD_ROW_H := 19.0
const CHILDREN_MAX_H := 220.0
const MAX_BACKLINKS_VISIBLE := 60
const BACKLINK_ROW_H := 19.0
const BACKLINKS_MAX_H := 220.0
## Desktop preview floor: the corner card sizes itself to its content, so the
## preview needs a height to make the card open tall enough to read. Phone
## rail/sheet are fixed-size, so there the preview shrinks and scrolls instead.
const PREVIEW_MIN_H := 200.0

@onready var column: VBoxContainer = %CardColumn
@onready var kind_label: Label = %CardKind
@onready var title_label: Label = %CardTitle
@onready var tags_chips: HFlowContainer = %CardTags
@onready var tabs_row: HBoxContainer = %CardTabs
@onready var tab_content: Button = %TabContent
@onready var tab_children: Button = %TabChildren
@onready var tab_backlinks: Button = %TabBacklinks
@onready var links_row: HBoxContainer = %LinksRow
@onready var links_header: Label = %CardLinksHeader
@onready var links_btn: Button = %CardLinksBtn
@onready var children_header: Label = %CardChildrenHeader
@onready var children_scroll: ScrollContainer = %CardChildrenScroll
@onready var children_box: VBoxContainer = %CardChildren
@onready var backlinks_header: Label = %CardBacklinksHeader
@onready var backlinks_scroll: ScrollContainer = %CardBacklinksScroll
@onready var backlinks_box: VBoxContainer = %CardBacklinks
@onready var preview_scroll: ScrollContainer = %CardPreviewScroll
@onready var preview_box: VBoxContainer = %CardPreview
@onready var meta_spacer: Control = %CardMetaSpacer
@onready var meta_label: Label = %CardMeta

var _model := {}
## The card's active tab: the note's own content, the child list (folder cards
## only), or the notes linking here. Content stays first so a focused node keeps
## showing its preview by default.
var _tab := "content"
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
	tab_backlinks.pressed.connect(func(): _set_tab("backlinks"))
	# The title doubles as an "open note" affordance, like the circle menu's
	# Open action; the label needs to stop ignoring the mouse to receive taps.
	title_label.mouse_filter = Control.MOUSE_FILTER_STOP
	title_label.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	title_label.gui_input.connect(_on_title_input)
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)
	GameManager.font_changed.connect(apply_theme)

## The title is a tap target: opening the note reuses Main's `_open_graph_note`,
## the same flow as the circle menu's Open (so a folder companion or the hub
## opens too). Emits the model's rel so Main never guesses what was focused.
func _on_title_input(event: InputEvent) -> void:
	var pressed: bool = (event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) \
		or (event is InputEventScreenTouch and event.pressed)
	if not pressed:
		return
	var rel := String(_model.get("rel", ""))
	if rel != "":
		title_opened.emit(rel)
	accept_event()

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
	for tab in [tab_content, tab_children, tab_backlinks]:
		tab.add_theme_color_override("font_color", c["accent2"])
		tab.add_theme_color_override("font_disabled_color", c["accent"])
		tab.add_theme_font_size_override("font_size", 12)
	children_header.add_theme_color_override("font_color", Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.75))
	backlinks_header.add_theme_color_override("font_color", Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.75))
	meta_label.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
	# Header labels are small captions; the title carries the hierarchy.
	for caption in [links_header, children_header, backlinks_header]:
		caption.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 4))
	meta_label.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
	_style_scrollbar(children_scroll)
	_style_scrollbar(backlinks_scroll)
	_style_scrollbar(preview_scroll)
	if not _model.is_empty():
		_render()

## Touch-friendly grabber, matching the preview/tree scrollbars.
func _style_scrollbar(scroll: ScrollContainer) -> void:
	var vsb := scroll.get_v_scroll_bar()
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
	_tab = "content"
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

	# A model swap can change kind while a tab is open (a folder card becomes
	# a note card, or vice versa): the child tab only exists for folders.
	if not is_folder and _tab == "children":
		_tab = "content"
	var show_body := _tab == "content"
	var show_children := is_folder and _tab == "children"
	var show_backlinks := _tab == "backlinks"

	_render_tags(_model.get("tags", []) as Array)
	# Every card exposes Content + Backlinks; a folder companion inserts the
	# Children tab between them, so Backlinks is its third tab.
	tabs_row.visible = true
	tab_children.visible = is_folder
	tab_content.disabled = _tab == "content"
	tab_children.disabled = _tab == "children"
	tab_backlinks.disabled = _tab == "backlinks"

	if is_folder:
		_render_children(_model.get("children", []) as Array)
	else:
		_clear(children_box)
	children_header.visible = show_children
	children_scroll.visible = show_children

	var has_links := _render_links()
	links_row.visible = not is_folder and show_body and has_links

	_render_backlinks(_model.get("backlinks", []) as Array)
	backlinks_header.visible = show_backlinks
	backlinks_scroll.visible = show_backlinks

	_render_preview(String(_model.get("preview", "")) if show_body else "")
	# The body scroll expands to fill the card; the spacer only pushes the meta
	# line to the bottom on the content tab when there is no preview.
	meta_spacer.visible = show_body and not preview_scroll.visible
	meta_label.text = _meta_text()
	meta_label.visible = show_body and meta_label.text != ""

## Render the note's opening lines exactly like the note preview, bounded to
## `GraphDigest.PREVIEW_LINES` source lines (the digest already truncated it).
## Same parser + builder as the note view, so headings, lists, code, quotes,
## tables and embeds look identical — just shorter. The build is synchronous
## because the digest caps the input, so it cannot stall the frame.
func _render_preview(source: String) -> void:
	if source.strip_edges() == "":
		preview_scroll.visible = false
		_clear(preview_box)
		return
	preview_scroll.visible = true
	preview_scroll.scroll_vertical = 0
	var doc := MarkdownParser.parse(source)
	# The card already shows the title, so drop the heading the builder would
	# otherwise prepend (the body carries no front matter, so it is empty).
	doc["meta"]["title"] = ""
	# The card always uses the app palette, never a per-note front-matter theme.
	PreviewBuilder.pal_override = {}
	PreviewBuilder.build(doc, preview_box)

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
## full links page so the excerpt keeps the card's space. Returns whether the
## row has anything to show (the caller owns its visibility on the tabs).
func _render_links() -> bool:
	var links: Array = _model.get("links", [])
	links_header.text = "⇢ LINKS · %d" % links.size()
	return not links.is_empty()

func _render_children(children: Array) -> void:
	_clear(children_box)
	children_header.text = "▣ %d NOTES" % children.size()
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

## Notes that link here. Rows are navigation like the child list: a press asks
## Main to focus that node on the map, which also enters any collapsed scope
## or page that currently hides it.
func _render_backlinks(backlinks: Array) -> void:
	_clear(backlinks_box)
	backlinks_header.text = "⇠ BACKLINKS · %d" % backlinks.size()
	backlinks_scroll.scroll_vertical = 0
	# Match the child list: size to the rows, but keep a real list scrollable.
	var rows := minf(backlinks.size(), MAX_BACKLINKS_VISIBLE)
	backlinks_scroll.custom_minimum_size = Vector2(0,
		maxf(BACKLINK_ROW_H, minf(rows * BACKLINK_ROW_H + 6.0, BACKLINKS_MAX_H)))
	var c := GameManager.palette()
	var shown := mini(backlinks.size(), MAX_BACKLINKS_VISIBLE)
	for i in shown:
		var entry: Dictionary = backlinks[i]
		var row := Button.new()
		row.text = "◈ " + String(entry.get("title", ""))
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_theme_color_override("font_color", Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.9))
		row.tooltip_text = String(entry.get("rel", ""))
		var rel := String(entry.get("rel", ""))
		row.pressed.connect(func(): backlink_selected.emit(rel))
		backlinks_box.add_child(row)
	if backlinks.size() > shown:
		backlinks_box.add_child(_more_label(backlinks.size() - shown))
	if backlinks.is_empty():
		var empty := Label.new()
		empty.text = "No notes link here."
		empty.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
		empty.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
		backlinks_box.add_child(empty)

## Passive overflow note (children list is scrollable, so it stays a label).
func _more_label(count: int) -> Label:
	var more := Label.new()
	more.text = "… +%d more" % count
	var c := GameManager.palette()
	more.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
	more.add_theme_font_size_override("font_size", maxi(11, GameManager.font_size - 3))
	return more

## Switch the card's tab and re-render in place. The child tab only exists on
## folder cards, so a stale note model never switches to it.
func _set_tab(tab: String) -> void:
	if _tab == tab:
		return
	if tab == "children" and String(_model.get("kind", "note")) != "folder":
		return
	_tab = tab
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
	if is_instance_valid(preview_scroll):
		preview_scroll.custom_minimum_size = Vector2(
			preview_scroll.custom_minimum_size.x, 0.0 if mobile else PREVIEW_MIN_H)

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
