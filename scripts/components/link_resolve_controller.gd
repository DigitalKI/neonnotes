class_name LinkResolveController
extends Node
## Wiki-link resolve flow: a clicked `[[target]]` that resolves to no note opens
## the resolve page (similar-note suggestions + explicit create) instead of
## silently creating a file; a suggestion re-points the link in place; `[[#tag]]`
## filters the tree without creating or opening anything.

const PAGE_LINK_RESOLVE := "link_resolve"

## Scene nodes + peers the host injects.
var vault_tree: VaultTreeComponent
var layout: LayoutComponent
var status_bar: StatusBarComponent
var editor: NoteEditor
var new_dialog: NewNoteDialog
var link_dialog: LinkResolveDialog
var page_router: PageRouter

## The unresolved target whose LinkResolveDialog page is open (set by open_wikilink).
var _link_target := ""


func setup() -> void:
	link_dialog.link_accepted.connect(accept_link)
	link_dialog.create_requested.connect(create_link)


## A preview/wiki-link click: route to the tree (a tag or a resolved note) or
## open the resolve page for an unresolved target.
func open_wikilink(target: String) -> void:
	# `[[#tag]]` is a tag reference, not a note: filter the tree by it and never
	# create a file (an unresolved `#foo` target used to become `#foo.md`).
	if target.strip_edges().begins_with("#"):
		vault_tree.filter_by_tag(target)
		# The results live in the tree; reveal the drawer on mobile.
		if layout.is_mobile_layout and not layout.drawer_open:
			layout.toggle_sidebar()
		status_bar.flash("Filtering " + target.strip_edges())
		return
	var fname := WikiLinks.resolve(target)
	if fname != "":
		vault_tree.select_note(fname)
		return
	# Unresolved: let the user decide — pick a similar note to re-point the
	# link, or explicitly create the note. No more silent auto-creation.
	_link_target = target
	page_router.open_page(PAGE_LINK_RESOLVE, link_dialog)
	link_dialog.open_for(target, _link_candidates())


## A suggested note was accepted: re-point the broken link and open it.
func accept_link(value: String) -> void:
	var rel := WikiLinks.resolve(value)
	var changed := editor.replace_wikilink(_link_target, value)
	if changed == 0:
		status_bar.flash("Link not found: " + _link_target)
		return
	if rel != "":
		vault_tree.select_note(rel)
	else:
		page_router.close_page()
	status_bar.flash("✓ Re-pointed " + _link_target)


## The user chose to create the unresolved target as a new note.
func create_link(target: String) -> void:
	var fname := new_dialog.create_note_for_link(target)
	if fname == "":
		# Recoverable: an invalid target leaves the dialog open with its
		# suggestions so the user can pick one instead.
		status_bar.flash("✗ Cannot create: " + target)
		return
	status_bar.flash("Created " + fname)


## Link target to write for `rel`: the bare name when it is unique across the
## vault (Obsidian-friendly), otherwise the vault-relative path.
func _link_target_for(rel: String) -> String:
	var noext := rel.trim_suffix(".md")
	var base := noext.get_file()
	for other in GameManager.notes:
		if other != rel and String(other).trim_suffix(".md").get_file() == base:
			return noext
	return base


## Every note as a ranking candidate: match on the vault path and the bare name.
func _link_candidates() -> Array:
	var out: Array = []
	for rel in GameManager.notes:
		var r := String(rel)
		if not r.ends_with(".md"):
			continue
		var noext := r.trim_suffix(".md")
		var base := noext.get_file()
		var title := String(GameManager.titles.get(r, ""))
		out.append({
			"rel": r,
			"label": title if title != "" else base,
			"value": _link_target_for(r),
			"keys": [noext, base],
		})
	return out
