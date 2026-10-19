class_name PageRouter
extends Node
## Page router: which full-screen page owns %Content. Every in-app page is a
## scene instance inside %Content; `open_page`/`close_page` hide the note column,
## show/hide the page, and hide/restore the graph. `page_mode` is the single
## source of truth (exposed to the shell as `Main.page_mode`).

var page_mode := ""

## Scene nodes + peers the host injects.
var editor: NoteEditor
var layout: LayoutComponent
var graph_shell: GraphShellComponent
var note_column: MarginContainer
var code_edit: CodeEdit
var edit_padding: MarginContainer
var content_host: ScrollContainer
## `() -> void` — keep the ⋮ menu's Undo/Redo rows truthful after a route.
var sync_more_edit_actions: Callable
## The page instances, in show/hide order (scene-authored inside %Content).
var pages: Array[Control] = []


func open_page(mode: String, page: Control) -> void:
	editor.flush()
	page_mode = mode
	editor.page_mode = mode
	# A page owns the whole screen on mobile, same as opening a note:
	# collapse the tree drawer first.
	if layout.is_mobile_layout and layout.drawer_open:
		layout.toggle_sidebar()
	# Hide the map and remember nothing more than how to bring it back: the dock
	# (or the full view) is restored when this page closes (see close_page).
	graph_shell.hide_for_page()
	note_column.visible = false
	code_edit.visible = false
	edit_padding.visible = false
	content_host.visible = false
	for p in pages:
		p.visible = p == page
	sync_more_edit_actions.call()


func close_page() -> void:
	page_mode = ""
	editor.page_mode = ""
	for p in pages:
		p.visible = false
	note_column.visible = true
	graph_shell.restore_after_page()
	editor.apply_mode()
