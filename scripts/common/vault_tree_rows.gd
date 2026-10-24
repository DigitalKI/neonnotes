class_name VaultTreeRows
extends RefCounted
## Shared row vocabulary + builder for vault trees. The sidebar and the Move
## page render the same thing — a folder hierarchy where a note whose stem is a
## folder (`x.md` + `x/`) is ONE merged row — so the row rules live here once
## instead of in two components that can drift apart.
##
## Row semantics:
##   * folder row           → `▸ name`,  metadata = the folder path
##   * folder-as-note row   → `◈ title`, metadata = the companion note path
##   * note leaf            → `◈ title`, metadata = the note path
##   * root row             → `root_text`, metadata = `root_metadata` ("" = vault root)
## `node_rel()` resolves any row back to a path, `destination()` resolves it to
## the folder a move into that row would land in.
##
## Two build shapes cover every caller:
##   * browse (`folders_first = true`) — declare every folder row, then its
##     notes, so a folder always precedes the notes it holds (the sidebar's
##     two-pass shape; `extra_dirs` declares folders that hold no notes);
##   * results (`folders_first = false`) — insert notes in the given order,
##     creating ancestor rows on demand (search results, filtered destinations).
##
## Options (all optional, shared by `build()`/`add_result()`/`add_dir()`):
##   root_text, root_tooltip, root_metadata, root_foldable
##   inbox / inbox_text / inbox_tooltip   pin the Inbox row first
##   extra_dirs       Array[String] folders to declare even without notes
##   dir_matches      Array[String] folders a results build must show
##   folders_first    browse shape (true) vs results shape (false)
##   expand_all       create folder rows expanded (filtered views)
##   collapsed        Callable(rel) -> bool, folder collapse state
##   exclude          Callable(rel) -> bool, hide a row and its subtree
##   order            Callable(dir) -> Array[String], leaf order in browse shape
##   titles           label rows with the front-matter title (true)
##   leaf_tooltip     Callable(rel) -> String
##   folder_tooltip   Callable(rel) -> String

const FOLDER_GLYPH := "▸ "
const NOTE_GLYPH := "◈ "


# ------------------------------------------------------------------ building

## Create the root row (`Vault` / `🏠 Vault (root)`); its metadata is the vault
## root destination (""). The root is selectable so it can be a move target.
static func make_root(tree: Tree, opts := {}) -> TreeItem:
	var root := tree.create_item()
	if root == null:
		# Godot returns null when the Tree is outside the scene tree and, more
		# commonly, during a mouse selection event. Callers that rebuild from a
		# Tree signal must defer; never dereference this null.
		push_error("VaultTreeRows: the Tree refused a new root item (is it inside the tree, and is this a deferred rebuild?)")
		return null
	root.set_text(0, str(opts.get("root_text", "Vault")))
	var tip := str(opts.get("root_tooltip", ""))
	if tip != "":
		root.set_tooltip_text(0, tip)
	root.set_metadata(0, str(opts.get("root_metadata", "")))
	root.disable_folding = not bool(opts.get("root_foldable", false))
	root.collapsed = false
	root.set_selectable(0, true)
	return root


## Build a whole tree from `notes` (vault-relative, already filtered).
## Returns `{"root": TreeItem, "folders": {rel: TreeItem}}`; the folder map is
## what a batched results build reuses across frames.
static func build(tree: Tree, notes: Array, opts := {}) -> Dictionary:
	var folders := {}
	var root := make_root(tree, opts)
	if root == null:
		return {"root": null, "folders": folders}
	var excluded: Callable = opts.get("exclude", Callable())
	if bool(opts.get("inbox", false)):
		_add_inbox(tree, root, folders, opts)
	var order: Callable = opts.get("order", Callable())
	var by_dir := {}
	if not order.is_valid():
		for n in notes:
			var rel := str(n)
			if _excluded(excluded, rel):
				continue
			var dir := rel.get_base_dir()
			if not by_dir.has(dir):
				by_dir[dir] = []
			by_dir[dir].append(rel)
	if bool(opts.get("folders_first", true)):
		# pass 1: every folder row before any leaf, so folders sort first.
		for dir in opts.get("extra_dirs", []):
			_ensure_dir(tree, root, str(dir), folders, opts)
		for n in notes:
			var rel := str(n)
			if _excluded(excluded, rel):
				continue
			var dir := rel.get_base_dir()
			if dir != "":
				_ensure_dir(tree, root, dir, folders, opts)
		# pass 2: leaves, per folder in the caller's order, then the root's.
		for dir in folders.keys():
			for n in _leaves_for(str(dir), opts, by_dir):
				_add_leaf(tree, folders[dir], n, opts)
		for n in _leaves_for("", opts, by_dir):
			_add_leaf(tree, root, n, opts)
	else:
		# results shape: matching folders first, then hits in relevance order.
		for dir in opts.get("dir_matches", []):
			add_dir(tree, folders, str(dir), opts)
		for n in notes:
			add_result(tree, folders, str(n), opts)
	return {"root": root, "folders": folders}


## Append one note to a results-shaped tree, creating ancestor rows on demand.
## A note that is a folder's companion becomes that folder's merged row.
static func add_result(tree: Tree, folders: Dictionary, rel: String, opts := {}) -> TreeItem:
	if rel == "" or _excluded(opts.get("exclude", Callable()), rel):
		return null
	if rel.ends_with(".md") and folder_exists(rel.trim_suffix(".md")):
		return add_dir(tree, folders, rel.trim_suffix(".md"), opts)
	var parent := _ensure_dir(tree, tree.get_root(), rel.get_base_dir(), folders, opts)
	return _add_leaf(tree, parent, rel, opts)


## Ensure the row for `dir` (and its ancestors) exists; returns its row.
static func add_dir(tree: Tree, folders: Dictionary, dir: String, opts := {}) -> TreeItem:
	return _ensure_dir(tree, tree.get_root(), dir, folders, opts)


# ---------------------------------------------------------------- resolving

## The vault-relative path a row stands for: a merged folder row counts as its
## FOLDER, so every move/drag/reveal path resolves the same way everywhere.
## "" is the vault root.
static func node_rel(item: TreeItem) -> String:
	if item == null or not is_instance_valid(item) or item.get_metadata(0) == null:
		return ""
	var meta := str(item.get_metadata(0))
	if meta.ends_with(".md") and folder_exists(meta.trim_suffix(".md")):
		return meta.trim_suffix(".md")
	return meta


## The destination folder a move onto this row would use: a folder path, the
## stem of a standalone note (moving onto a note turns it into a folder, exactly
## like a drop), or "" for the vault root.
static func destination(item: TreeItem) -> String:
	var rel := node_rel(item)
	if rel.ends_with(".md"):
		return rel.trim_suffix(".md")
	return rel


## First row resolving to `rel` ("" = the root row), depth-first. A row carries
## either the folder/note path or a folder's companion note, so both spellings
## of the same row match without touching the disk.
static func find(tree: Tree, rel: String) -> TreeItem:
	var root := tree.get_root()
	if root == null:
		return null
	if rel == "":
		return root
	var stack: Array[TreeItem] = [root]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		var meta := str(it.get_metadata(0))
		if meta == rel or meta == rel + ".md":
			return it
		for c in it.get_children():
			stack.append(c)
	return null


## True when `rel` is a real folder in the vault (a note `x.md` whose `x/`
## exists is the folder's companion, not a separate row).
static func folder_exists(rel: String) -> bool:
	if rel == "":
		return false
	return DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(rel))


## Every visible folder in the vault (vault-relative, depth-first, alphabetical;
## dot-folders such as .trash stay hidden). Used by the Move page, which offers
## folders that hold no notes yet as destinations too.
static func vault_dirs() -> Array[String]:
	var out: Array[String] = []
	_collect_dirs("", out)
	return out


## Notes in `lst` ordered by the vault's custom order for `dir`, then
## alphabetically. Shared by the tree's two build shapes.
static func sort_notes(lst: Array[String], dir: String) -> Array[String]:
	var want: Array = GameManager.order.get(dir, [])
	lst.sort_custom(func(a: String, b: String) -> bool:
		var ia := want.find(a)
		var ib := want.find(b)
		if ia == -1 and ib == -1:
			return a < b
		if ia == -1:
			return false
		if ib == -1:
			return true
		return ia < ib)
	return lst


# ------------------------------------------------------------------ internals

static func _collect_dirs(rel: String, out: Array[String]) -> void:
	var abs := GameManager.vault_abs() if rel == "" else GameManager.vault_abs().path_join(rel)
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.include_hidden = true
	var names: Array[String] = []
	for name in d.get_directories():
		if String(name).begins_with("."):
			continue
		names.append(String(name))
	names.sort()
	for name in names:
		var child := (rel + "/" if rel != "" else "") + name
		out.append(child)
		_collect_dirs(child, out)


static func _add_inbox(tree: Tree, root: TreeItem, folders: Dictionary, opts: Dictionary) -> void:
	if root == null:
		return
	var rel: String = GameManager.INBOX_DIR
	var it := tree.create_item(root)
	it.set_text(0, str(opts.get("inbox_text", "📥 Inbox")))
	it.set_tooltip_text(0, str(opts.get("inbox_tooltip", "Inbox")))
	it.set_metadata(0, rel + ".md")  # clicking opens the companion note
	it.set_selectable(0, true)
	it.collapsed = _collapsed(rel, opts)
	folders[rel] = it


static func _ensure_dir(tree: Tree, root: TreeItem, dir: String, folders: Dictionary,
		opts: Dictionary) -> TreeItem:
	if root == null:
		return null
	if dir == "" or dir == ".":
		return root
	var excluded: Callable = opts.get("exclude", Callable())
	var parent := root
	var path := ""
	for part in dir.split("/"):
		path = (path + "/" if path != "" else "") + part
		if _excluded(excluded, path):
			return null
		if not folders.has(path):
			var it := tree.create_item(parent)
			_folder_row(it, path, opts)
			folders[path] = it
		parent = folders[path]
	return parent


static func _folder_row(it: TreeItem, rel: String, opts: Dictionary) -> void:
	var companion := rel + ".md"
	var merged: bool = GameManager.notes.has(companion)
	if merged:
		it.set_text(0, NOTE_GLYPH + _label(companion, opts))
	else:
		it.set_text(0, FOLDER_GLYPH + rel.get_file())
	it.set_tooltip_text(0, _folder_tooltip(rel, opts))
	it.set_metadata(0, companion if merged else rel)
	it.set_selectable(0, true)
	it.collapsed = false if bool(opts.get("expand_all", false)) else _collapsed(rel, opts)


static func _add_leaf(tree: Tree, parent: TreeItem, rel: String, opts: Dictionary) -> TreeItem:
	if parent == null or rel == "" or _excluded(opts.get("exclude", Callable()), rel):
		return null
	# A note whose stem is a folder is that folder's companion: one merged row,
	# never a folder row plus a duplicate leaf (INV-011).
	if rel.ends_with(".md") and folder_exists(rel.trim_suffix(".md")):
		return null
	var leaf := tree.create_item(parent)
	leaf.set_text(0, NOTE_GLYPH + _label(rel, opts))
	leaf.set_tooltip_text(0, _leaf_tooltip(rel, opts))
	leaf.set_metadata(0, rel)
	leaf.set_selectable(0, true)
	return leaf


static func _leaves_for(dir: String, opts: Dictionary, by_dir: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var order: Callable = opts.get("order", Callable())
	if order.is_valid():
		for n in order.call(dir):
			out.append(str(n))
		return out
	for n in by_dir.get(dir, []):
		out.append(str(n))
	return out


static func _label(rel: String, opts: Dictionary) -> String:
	if bool(opts.get("titles", true)):
		var title: String = GameManager.titles.get(rel, "")
		if title != "":
			return title
	return rel.get_file().trim_suffix(".md")


static func _leaf_tooltip(rel: String, opts: Dictionary) -> String:
	var cb: Callable = opts.get("leaf_tooltip", Callable())
	if cb.is_valid():
		return str(cb.call(rel))
	return rel.get_file().trim_suffix(".md")


static func _folder_tooltip(rel: String, opts: Dictionary) -> String:
	var cb: Callable = opts.get("folder_tooltip", Callable())
	if cb.is_valid():
		return str(cb.call(rel))
	return rel


static func _collapsed(rel: String, opts: Dictionary) -> bool:
	var cb: Callable = opts.get("collapsed", Callable())
	return bool(cb.call(rel)) if cb.is_valid() else true


static func _excluded(cb: Callable, rel: String) -> bool:
	return rel != "" and cb.is_valid() and bool(cb.call(rel))
