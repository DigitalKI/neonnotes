class_name LinkResolveDialog
extends MarginContainer
## Unresolved-wikilink page: when a `[[target]]` does not resolve to a note,
## this page lists the most similar vault notes (Levenshtein ranking, distance
## cap adjustable live) so the user can re-point the link instead of silently
## creating a duplicate file. A "Create new note" button always remains as the
## explicit fallback.
##
## Scene-authored page inside %Content (see scenes/components/
## link_resolve_dialog.tscn), shown by main.gd through the shared page helper.
## The host owns the decision side-effects (rewrite the link / create the note)
## and receives them via the link_accepted / create_requested signals.

signal close_requested
## A suggested note was chosen; `value` is the link target to write into the
## editor (a unique bare name, or a vault-relative path when ambiguous).
signal link_accepted(value: String)
## The user chose to create the unresolved target as a new note.
signal create_requested(target: String)

const MAX_ROWS := 8

## Preloaded so the script parses even before the global class cache is built
## (see TagMatch). TextMatch is pure and dependency-free.
const TextMatchScript := preload("res://scripts/common/text_match.gd")

@onready var target_label: Label = %TargetLabel
@onready var dist_spin: SpinBox = %DistSpin
@onready var list: VBoxContainer = %SuggestList
@onready var empty_label: Label = %EmptyLabel
@onready var create_btn: Button = %CreateBtn
@onready var close_btn: Button = %CloseButton

var _target := ""
var _candidates: Array = []


func _ready() -> void:
	visible = false
	dist_spin.value_changed.connect(func(_v: float): _rebuild())
	create_btn.pressed.connect(func(): create_requested.emit(_target))
	close_btn.pressed.connect(func(): close_requested.emit())


## Called by the host when the page is shown. `candidates` are note entries:
## {"rel": String, "label": String, "value": String, "keys": Array[String]}.
func open_for(target: String, candidates: Array) -> void:
	_target = target
	_candidates = candidates
	target_label.text = "[[" + target + "]]"
	create_btn.text = "✓ Create \"" + target + "\""
	_rebuild()
	if list.get_child_count() > 0:
		list.get_child(0).grab_focus()
	else:
		create_btn.grab_focus()


func _rebuild() -> void:
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	var ranked := TextMatchScript.rank(_target, _candidates, int(dist_spin.value), MAX_ROWS)
	empty_label.visible = ranked.is_empty()
	empty_label.text = "No similar notes — create it?"
	for r in ranked:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var label := String(r.get("label", ""))
		var rel := String(r.get("rel", "")).trim_suffix(".md")
		var near := int(r.get("score", 0)) >= 2
		b.text = label + "    ·  " + rel + (("    (d=" + str(int(r.get("distance", 0))) + ")") if near else "")
		b.tooltip_text = "Re-point the link to " + rel
		b.pressed.connect(func(): link_accepted.emit(String(r.get("value", ""))))
		list.add_child(b)
