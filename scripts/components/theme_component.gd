class_name ThemeComponent
extends Node

## Applies the active GameManager palette to the authored UI shell.
## Owns: styleboxes/fonts/colors for SidePanel, Content, titles, toolbar
## buttons, and the source CodeEdit (incl. NeonHighlighter).
## Call apply() whenever GameManager.palette_changed fires; the host keeps
## the palette_changed connection (it also re-renders the preview).
##
## Also owns the user-selected font family + size (GameManager.font_changed):
## a runtime Theme on the window root supplies the default font/default size,
## and every authored `font_size` override captured at setup is re-applied as
## `authored + GameManager.font_delta()`, so the whole shell scales together.

var bg: ColorRect
var note_title: Label
var side_panel: PanelContainer
var content_panel: PanelContainer
var toolbar: Control
var code_edit: CodeEdit
var root_ctl: Control

## Authored `font_size` overrides (node -> base points), captured once in
## setup() before any theme change so apply() can rescale them idempotently.
var _base_font_sizes: Dictionary = {}
var _app_theme: Theme


func setup(p_bg: ColorRect, p_note_title: Label,
		p_side_panel: PanelContainer, p_content_panel: PanelContainer,
		p_toolbar: Control, p_code_edit: CodeEdit, p_root: Control) -> void:
	bg = p_bg
	note_title = p_note_title
	side_panel = p_side_panel
	content_panel = p_content_panel
	toolbar = p_toolbar
	code_edit = p_code_edit
	root_ctl = p_root
	_capture_font_sizes(p_root)


## Record every control's authored font size before the runtime theme exists.
## The note title is skipped: LayoutComponent owns its size (it also varies by
## orientation), so it applies the font delta itself.
func _capture_font_sizes(node: Node) -> void:
	if node == note_title:
		return
	if node is Control and node.has_theme_font_size_override("font_size"):
		_base_font_sizes[node] = node.get_theme_font_size("font_size")
	for child in node.get_children():
		_capture_font_sizes(child)


func apply() -> void:
	var c := GameManager.palette()
	_apply_fonts()
	var orb: FontFile = load("res://assets/fonts/Orbitron.ttf")
	bg.color = c["bg"]
	var panel := StyleBoxFlat.new()
	panel.bg_color = c["panel"]
	panel.border_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.5)
	panel.set_border_width_all(2)
	side_panel.add_theme_stylebox_override("panel", panel)
	# Padding is authored on the preview/edit MarginContainers in Main.tscn so
	# the ScrollContainer scrollbar remains flush with the content panel edge.
	content_panel.add_theme_stylebox_override("panel", panel.duplicate())
	note_title.add_theme_font_override("font", orb)
	for btn in toolbar.get_children():
		if btn is Button:
			btn.add_theme_font_override("font", orb)
			# Landscape phones shrink all fonts by LayoutComponent.ui_font_delta,
			# which now also carries the user font-size delta.
			btn.add_theme_font_size_override("font_size", 13 - LayoutComponent.ui_font_delta)
	code_edit.add_theme_color_override("font_color", c["text"])
	code_edit.add_theme_color_override("background_color", Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.7))
	code_edit.add_theme_color_override("current_line_color", Color(c["panel"].r, c["panel"].g, c["panel"].b, 0.9))
	# Reuse the existing highlighter when possible: it carries the live
	# in-document find state (search_query / search_current), which a palette or
	# font change must not wipe.
	var hl: NeonHighlighter = code_edit.syntax_highlighter as NeonHighlighter
	if hl == null:
		hl = NeonHighlighter.new()
	hl.colors = {
		"heading": c["accent"], "accent": c["accent"], "accent2": c["accent2"],
		"accent3": c["accent3"], "code": c["accent2"], "text": c["text"],
		"dim": Color(c["text"].r, c["text"].g, c["text"].b, 0.5),
		# CodeEdit syntax highlighting only honours a range's `color`, so the
		# find highlight is a font colour: all matches gold, the active one pink
		# (both full-opacity so they pop against the light body text).
		"search": c["accent3"],
		"search_current": c["accent"],
	}
	# Re-assigning forces CodeEdit to re-highlight; the setter ignores an
	# identical instance, so clear it to null first (see NeonHighlighter.set_search).
	code_edit.syntax_highlighter = null
	code_edit.syntax_highlighter = hl


## Default font family + size for the whole window (Controls without an
## explicit override inherit these), plus a rescale of the captured authored
## sizes. Assigning on the window root also lets PNG/GIF exports inherit it.
func _apply_fonts() -> void:
	if _app_theme == null:
		_app_theme = Theme.new()
	_app_theme.default_font = GameManager.font()
	_app_theme.default_font_size = GameManager.font_size
	var tree := root_ctl.get_tree() if is_instance_valid(root_ctl) else get_tree()
	if tree != null and tree.root != null:
		tree.root.theme = _app_theme
	var delta := GameManager.font_delta()
	for node in _base_font_sizes:
		if is_instance_valid(node):
			node.add_theme_font_size_override("font_size", int(_base_font_sizes[node]) + delta)
