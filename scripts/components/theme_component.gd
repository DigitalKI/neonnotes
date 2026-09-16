class_name ThemeComponent
extends Node

## Minimal inner padding for the editor + preview panes.
const CONTENT_PAD := 14
## Applies the active GameManager palette to the authored UI shell.
## Owns: styleboxes/fonts/colors for SidePanel, Content, titles, toolbar
## buttons, and the source CodeEdit (incl. NeonHighlighter).
## Call apply() whenever GameManager.palette_changed fires; the host keeps
## the palette_changed connection (it also re-renders the preview).

var bg: ColorRect
var title_label: Label
var note_title: Label
var side_panel: PanelContainer
var content_panel: PanelContainer
var toolbar: Control
var code_edit: CodeEdit


func setup(p_bg: ColorRect, p_title: Label, p_note_title: Label,
		p_side_panel: PanelContainer, p_content_panel: PanelContainer,
		p_toolbar: Control, p_code_edit: CodeEdit) -> void:
	bg = p_bg
	title_label = p_title
	note_title = p_note_title
	side_panel = p_side_panel
	content_panel = p_content_panel
	toolbar = p_toolbar
	code_edit = p_code_edit


func apply() -> void:
	var c := GameManager.palette()
	var orb: FontFile = load("res://assets/fonts/Orbitron.ttf")
	bg.color = c["bg"]
	var panel := StyleBoxFlat.new()
	panel.bg_color = c["panel"]
	panel.border_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.5)
	panel.set_border_width_all(2)
	side_panel.add_theme_stylebox_override("panel", panel)
	# Minimal inner padding so both the editor (CodeEdit) and preview column sit
	# off the panel edge instead of touching it. Shared panel stylebox is used for
	# the sidebar; the content pane gets its own padded copy.
	var content_style: StyleBoxFlat = panel.duplicate()
	content_style.set_content_margin_all(CONTENT_PAD)
	content_panel.add_theme_stylebox_override("panel", content_style)
	title_label.add_theme_font_override("font", orb)
	note_title.add_theme_font_override("font", orb)
	for btn in toolbar.get_children():
		if btn is Button:
			btn.add_theme_font_override("font", orb)
			btn.add_theme_font_size_override("font_size", 13)
	code_edit.add_theme_color_override("font_color", c["text"])
	code_edit.add_theme_color_override("background_color", Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.7))
	code_edit.add_theme_color_override("current_line_color", Color(c["panel"].r, c["panel"].g, c["panel"].b, 0.9))
	var hl := NeonHighlighter.new()
	hl.colors = {
		"heading": c["accent"], "accent": c["accent"], "accent2": c["accent2"],
		"accent3": c["accent3"], "code": c["accent2"], "text": c["text"],
		"dim": Color(c["text"].r, c["text"].g, c["text"].b, 0.5),
	}
	code_edit.syntax_highlighter = hl
