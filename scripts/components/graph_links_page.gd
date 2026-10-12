class_name GraphLinksPage
extends MarginContainer
## Full-screen page listing every note a note links out to — opened from the
## focus card's links button, so the card itself stays a compact digest. Rows
## are navigation, not text: a press asks Main to reach that note (map focus,
## or the wikilink resolve flow for unresolved targets). Structure is authored
## in scenes/components/graph_links_page.tscn, laid out like the other pages.

signal link_activated(target: String, resolved: String)
signal close_requested

@onready var title_label: Label = %Title
@onready var hint: Label = %Hint
@onready var list: VBoxContainer = %List
@onready var close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	close_btn.pressed.connect(func(): close_requested.emit())
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)

## Populate for one note. `links` entries are the card view-model's
## {raw, label, resolved} records.
func open(note_title: String, links: Array) -> void:
	title_label.text = "⇢ LINKS · %s" % note_title
	hint.visible = not links.is_empty()
	_clear()
	var c := GameManager.palette()
	for entry in links:
		var resolved := String(entry.get("resolved", ""))
		var row := Button.new()
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.text = "→ " + String(entry.get("label", ""))
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.tooltip_text = resolved if resolved != "" else "Unresolved link"
		if resolved == "":
			row.add_theme_color_override("font_color",
				Color(c["text"].r, c["text"].g, c["text"].b, 0.45))
		else:
			row.add_theme_color_override("font_color", c["accent2"])
		var target := String(entry.get("raw", ""))
		var dest := resolved
		row.pressed.connect(func(): link_activated.emit(target, dest))
		list.add_child(row)
	if links.is_empty():
		var empty := Label.new()
		empty.text = "No outgoing links."
		empty.add_theme_color_override("font_color",
			Color(c["text"].r, c["text"].g, c["text"].b, 0.5))
		list.add_child(empty)

func _clear() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()

func apply_theme() -> void:
	var c := GameManager.palette()
	hint.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.6))