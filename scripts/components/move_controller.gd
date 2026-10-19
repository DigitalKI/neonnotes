class_name MoveController
extends Node
## Note/folder move orchestration for the two entry points that funnel through
## the Move page: the ⋮ menu (moves the selected row, or the open note when
## nothing is selected) and the graph circle menu (returns to the map and
## re-focuses the moved node). The tree's drag path moves inline; only these two
## page-based flows go through here.

const PAGE_MOVE := "move"

## Scene nodes + peers the host injects.
var editor: NoteEditor
var vault_tree: VaultTreeComponent
var status_bar: StatusBarComponent
var move_dialog: MoveDialog
var graph_view: GraphView
var graph_shell: GraphShellComponent
var page_router: PageRouter
## `() -> void` — rebuild the tree + graph after the move commits.
var refresh_list: Callable

## True while the open Move page was launched from the graph circle menu, so
## finishing the move returns to the graph and re-focuses the moved node.
var _move_from_graph := false


func setup() -> void:
	move_dialog.moved.connect(on_note_moved)


## The ⋮ menu's Move action: relocate the selected tree row — a note OR a whole
## folder with its children — and, with nothing selected, the open note.
func move_selected() -> void:
	if editor.is_help():
		status_bar.flash("Nothing to move")
		return
	var rel := ""
	var it := vault_tree.selected_item()
	if it != null and it != vault_tree.side_tree.get_root():
		rel = vault_tree.node_rel(it)
	if rel == "":
		# No row selected: act on the open note, as before.
		rel = GameManager.current_rel
		rel = "" if rel == "_homepage.md" else rel
	if rel == "":
		status_bar.flash("Select a note or folder to move")
		return
	# Only the Inbox folder/companion is system-managed (auto-created, protected
	# from deletion like a dot-folder) and never relocatable; a capture inside it
	# is an ordinary note, so filing it out with ⋮ Move stays possible.
	if GameManager.is_inbox_root(rel):
		status_bar.flash("📥 The Inbox cannot be moved")
		return
	_move_from_graph = false
	page_router.open_page(PAGE_MOVE, move_dialog)
	move_dialog.begin(rel)


## The graph circle menu's Move action: relocate the focused node (a note or a
## whole folder); when it finishes the graph returns and re-focuses the target.
func move_graph_note(rel: String) -> void:
	if rel == "" or rel == "_homepage.md":
		status_bar.flash("⌂ The homepage cannot be moved")
		return
	_move_from_graph = true
	page_router.open_page(PAGE_MOVE, move_dialog)
	move_dialog.begin(rel)


## A move completed. The page never touched the editor buffer, so "keep the note
## open" is simply leaving it be; the tree and graph are rebuilt once here, then
## the view that started the move is restored.
func on_note_moved(old_rel: String, new_rel: String) -> void:
	var from_graph := _move_from_graph
	_move_from_graph = false
	# A folder move carries the open note along, but move_path only repoints
	# current_rel when the note itself was the target — remap it here so the
	# editor keeps saving to the note's new path.
	var cur := GameManager.current_rel
	if cur != "" and not GameManager.notes.has(cur):
		var remapped := PathRemap.moved(cur, old_rel, new_rel)
		if GameManager.notes.has(remapped):
			GameManager.current_rel = remapped
			GameManager.current_file = GameManager.vault_abs() + "/" + remapped
	# Same housekeeping a drag does: drop directories the move emptied and
	# re-run an active search before the tree is rebuilt.
	vault_tree.after_external_move(old_rel)
	refresh_list.call()
	if from_graph:
		graph_shell.return_to_graph()
		graph_view.refresh_graph()
		if not graph_view.focus_note(new_rel):
			# Off-page or folded into a group: open the note, or climb to the
			# nearest visible ancestor scope for a folder.
			if new_rel.ends_with(".md"):
				graph_shell.open_graph_note(new_rel)
			else:
				graph_view.focus_note(new_rel.get_base_dir())
	else:
		page_router.close_page()
		# Keep the note view as it was; move the tree selection to the moved
		# node (a merged folder row carries its companion as metadata).
		vault_tree.select_note(_selection_rel_after_move(new_rel), false)
	status_bar.flash("Moved → " + new_rel)


## The tree row to select after a move: a note's own path, or a folder's
## companion note (merged folder rows are matched by their companion metadata).
func _selection_rel_after_move(new_rel: String) -> String:
	if new_rel.ends_with(".md"):
		return new_rel
	var companion := new_rel + ".md"
	return companion if GameManager.notes.has(companion) else new_rel
