class_name GraphSearchBar
extends PanelContainer
## Visual-search chrome for the graph map: the same `keywords + #tags` query
## the sidebar tree runs (VaultSearch), authored as a scene so it stays
## editable like every other graph chrome (nav bar, view toolbar). It sits at
## the top-right of the map, below the nav bar.
##
## The bar is presentational: it publishes the typed text via `query_changed`
## and mirrors the matching state via `set_report` — the matching itself lives
## in GraphView (it owns the node set), debounced through VaultSearchRunner
## like the sidebar, so body reads never touch the main thread (INV-015).
## Typing `#` rides the sidebar's own TagSuggest overlay (INV-059: it is added
## deferred — the bar readies while the main scene is still wiring children —
## and it parents to the scene root, because the map control clips contents).

signal query_changed(text: String)

const TAG_SUGGEST_SCENE := preload("res://scenes/components/tag_suggest.tscn")

@onready var query: LineEdit = %Query
@onready var count_label: Label = %Matches

## The shared tag-autocomplete overlay; lives on the scene root, not in the bar.
var _suggest: TagSuggest

func _ready() -> void:
	query.text_changed.connect(func(t: String): query_changed.emit(t))
	_setup_tag_suggest()
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)

## Tag autocomplete, wired like the sidebar's search field (the same TagSuggest
## scene, INLINE mode): `#token` under the caret lists vault tags ranked
## prefix -> substring -> near-match; accepting a row rewrites the token. A
## programmatic rewrite does not emit text_changed, so the chosen tag
## re-publishes the query for the view to re-run. The overlay parents to the
## current scene (the bar sits under GraphView, which clips contents), falling
## back to the bar when no scene exists (standalone/probe use).
func _setup_tag_suggest() -> void:
	var overlay_parent := get_tree().current_scene
	if overlay_parent == null:
		overlay_parent = self
	# Deferred add: the bar readies while the main scene is still setting up
	# its children (INV-059) — a deferred add_child lands on a stable tree.
	_suggest = TAG_SUGGEST_SCENE.instantiate()
	overlay_parent.add_child.call_deferred(_suggest)
	_suggest.bind(query, TagSuggest.Mode.INLINE)
	_suggest.tag_chosen.connect(func(_tag: String):
		query_changed.emit(query.text))

## The overlay floats on the scene root, above both the dock and the full view:
## whenever the map itself hides (dock toggle, page swap, drawer slide), pull it.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible \
			and _suggest != null and is_instance_valid(_suggest):
		_suggest.close()

func _exit_tree() -> void:
	# An overlay parented to the scene root must not outlive its bar.
	if _suggest != null and is_instance_valid(_suggest) and _suggest.get_parent() != self:
		_suggest.queue_free()
		_suggest = null

## Mirror GraphView's search state: idle hides the counter, a pending worker
## shows "…", results show the matched-note count.
func set_report(report: Dictionary) -> void:
	var state := String(report.get("state", "idle"))
	match state:
		"pending":
			count_label.visible = true
			count_label.text = "…"
		"done":
			count_label.visible = true
			count_label.text = str(maxi(0, int(report.get("count", 0))))
		_:
			count_label.visible = false
			count_label.text = ""

## Programmatic query set. Used in place of typing: a LineEdit assignment does
## not emit text_changed, so this mirrors the field and publishes the query.
func set_query(text: String) -> void:
	query.text = text
	query_changed.emit(text)

## Neon chrome: a transparent panel like the nav bar; the counter rides accent2.
func apply_theme() -> void:
	var c := GameManager.palette()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.0)
	panel.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel)
	count_label.add_theme_color_override("font_color", c["accent2"])
	count_label.add_theme_font_size_override("font_size", 12)