class_name VaultMove
extends RefCounted
## Pure vault move/rename + wiki-link rewrite + empty-folder pruning, extracted
## from VaultTreeComponent (2026-10-16). All static and stateless: they operate
## on GameManager's global state, the vault on disk, and the injected `moved_cb`
## (which reports old/new paths so the caller can raise sync tombstones). The
## tree controller keeps the facade `move_path()` so every move — drag, Move
## page, graph radial menu, delete-child — still funnels through one code path.

## Move a note or folder (vault-relative) into `dst_dir` ("" = vault root).
## Auto-renames on collision. Returns the new relative path ("" on failure).
## `moved_cb(old_paths, new_paths)` is called on success so the caller can mark
## tombstones / clear peer tombstones.
static func move_path(src_rel: String, dst_dir: String, moved_cb: Callable) -> String:
	# The Inbox folder/companion is system-managed and never relocatable — the
	# single choke point every move path (drag, Move page, graph) funnels through.
	if GameManager.is_inbox_root(src_rel):
		return ""
	var old_paths := _paths_under(src_rel)
	var vault := GameManager.vault_abs()
	var src := vault.path_join(src_rel)
	if not FileAccess.file_exists(src) and not DirAccess.dir_exists_absolute(src):
		return ""
	# never drop a folder into itself or one of its children
	if not src_rel.ends_with(".md") and (dst_dir == src_rel or dst_dir.begins_with(src_rel + "/")):
		return ""
	# companion note should not be moved into its own companion folder
	if src_rel.ends_with(".md") and dst_dir == src_rel.trim_suffix(".md"):
		return src_rel

	var dst := vault if dst_dir == "" else vault.path_join(dst_dir)
	DirAccess.make_dir_recursive_absolute(dst)
	var base := src_rel.get_file()
	var target := dst.path_join(base)
	if src == target:
		return src_rel

	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var stem := base.trim_suffix(".md")
		var ext := ".md" if base.ends_with(".md") else ""
		var i := 2
		while FileAccess.file_exists(dst.path_join("%s-%d%s" % [stem, i, ext])) \
				or DirAccess.dir_exists_absolute(dst.path_join("%s-%d" % [stem, i])):
			i += 1
		target = dst.path_join("%s-%d%s" % [stem, i, ext])
	if DirAccess.rename_absolute(src, target) != OK:
		return ""
	var new_rel := target.trim_prefix(vault + "/")
	# Remap the in-memory index (paths only; titles/tags/links travel with the
	# files) before the link rewrites, so those rewrites pick their candidates
	# and write back at the paths the files now have — never the old ones.
	GameManager.remap_moved(src_rel, new_rel)
	if src_rel.ends_with(".md"):
		_rewrite_links(src_rel, new_rel)
	else:
		# moving a FOLDER: take its companion note along and rewrite every
		# [[old/sub/note]] link that pointed inside it
		var companion := src_rel + ".md"
		# companion follows the final folder name, including collision suffixes
		var comp_target := target.get_base_dir().path_join(target.get_file() + ".md")
		if FileAccess.file_exists(vault.path_join(companion)) and not FileAccess.file_exists(comp_target):
			DirAccess.rename_absolute(vault.path_join(companion), comp_target)
		_rewrite_folder_links(src_rel, new_rel)
	# Keep the open note consistent when the move carries it: the note itself,
	# any note inside a moved folder, or a folder's companion note. Repointing
	# only the exact source left a folder-note's companion on its old path (the
	# editor would keep saving there and the graph/tree lost the open row).
	var remapped_open := PathRemap.moved(GameManager.current_rel, src_rel, new_rel)
	if remapped_open != GameManager.current_rel:
		GameManager.current_rel = remapped_open
		GameManager.current_file = vault.path_join(remapped_open)
	if moved_cb.is_valid():
		# Report both the old and the new paths: the old ones become tombstones,
		# the new ones must clear any tombstone peers still hold for them (a
		# folder moved back onto a previously deleted path).
		var new_paths: Array[String] = []
		for p in old_paths:
			new_paths.append(PathRemap.moved(p, src_rel, new_rel))
		moved_cb.call(old_paths, new_paths)
	return new_rel


## Every vault-relative path under `rel` (a note file, or a folder subtree plus
## its companion note).
static func _paths_under(rel: String) -> Array[String]:
	var out: Array[String] = []
	var vault := GameManager.vault_abs()
	var base := vault.path_join(rel)
	if FileAccess.file_exists(base):
		out.append(rel)
		return out
	if not DirAccess.dir_exists_absolute(base):
		return out
	for f in DirAccess.get_files_at(base):
		out.append(rel.path_join(f))
	for d in DirAccess.get_directories_at(base):
		out.append_array(_paths_under(rel.path_join(d)))
	var companion := rel + ".md"
	if FileAccess.file_exists(vault.path_join(companion)):
		out.append(companion)
	return out


## Update [[wiki-links]] across the vault after a move/rename.
static func _rewrite_links(old_rel: String, new_rel: String) -> void:
	var old_noext := old_rel.trim_suffix(".md")
	var new_noext := new_rel.trim_suffix(".md")
	# Compile each pattern ONCE per move: the previous code re-created the
	# identical RegEx for every candidate note, which is pure CPU on the UI
	# thread and grows with vault size.
	var rules: Array = [[
		RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + TextUtils.re_escape(old_noext) + "(\\]\\]|\\|)"),
		"[[" + new_noext + "$1",
	]]
	var old_base := old_noext.get_file()
	var new_base := new_noext.get_file()
	if old_base != new_base:
		rules.append([
			RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + TextUtils.re_escape(old_base) + "(\\]\\]|\\|)"),
			"[[" + new_base + "$1",
		])
	# Only notes whose indexed links can match this move are rewritten.
	for n in _move_rewrite_candidates(old_rel):
		var path := GameManager.vault_abs().path_join(n)
		var t := TextIO.read_text(path)
		var orig := t
		if t.contains("[["):
			for rule in rules:
				t = (rule[0] as RegEx).sub(t, rule[1], true)
		if t != orig:
			GameManager.write_note(n, t)


## Update [[wiki-links]] across the vault after a folder move/rename.
static func _rewrite_folder_links(old_dir: String, new_dir: String) -> void:
	# Compiled once per move (was: once per candidate note).
	var folder_re := RegEx.create_from_string("(?i)(?<!\\\\)\\[\\[" + TextUtils.re_escape(old_dir) + "/")
	# Only notes whose indexed links can match the old folder prefix.
	for n in _move_rewrite_candidates(old_dir):
		var path := GameManager.vault_abs().path_join(n)
		var t := TextIO.read_text(path)
		var orig := t
		if t.contains("[["):
			t = folder_re.sub(t, "[[" + new_dir + "/", true)
		if t != orig:
			GameManager.write_note(n, t)


## Notes that could contain a link to the moved path. Backed by the link
## index so a move touches only affected notes; falls back to a full path
## walk when the index is not built (e.g. a vault that has not been scanned).
static func _move_rewrite_candidates(old_prefix: String) -> Array[String]:
	if not GameManager.links_ready:
		return GameManager.list_note_paths()
	return GameManager.notes_linking_to(old_prefix)


## Remove directories emptied by moving `rel` away, walking up only its own
## ancestor chain (the full-vault prune below is far more expensive).
static func prune_empty_ancestors(rel: String) -> void:
	var dir := rel.get_base_dir()
	while dir != "":
		var abs := GameManager.vault_abs().path_join(dir)
		if not DirAccess.dir_exists_absolute(abs):
			dir = dir.get_base_dir()
			continue
		if not DirAccess.get_directories_at(abs).is_empty() \
				or not DirAccess.get_files_at(abs).is_empty():
			return
		DirAccess.remove_absolute(abs)
		dir = dir.get_base_dir()


## Remove now-empty folders (bottom-up) so restructuring leaves no leftovers.
static func prune_empty_dirs() -> void:
	var changed := true
	while changed:
		changed = false
		for d in _all_dirs(""):
			var abs := GameManager.vault_abs().path_join(d)
			if DirAccess.get_directories_at(abs).is_empty() and DirAccess.get_files_at(abs).is_empty():
				if DirAccess.remove_absolute(abs) == OK:
					changed = true


static func _all_dirs(rel: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(GameManager.vault_abs() + ("/" + rel if rel != "" else ""))
	if d == null:
		return out
	for f in d.get_directories():
		if f.begins_with("."):
			continue
		var child := rel + ("/" if rel != "" else "") + f
		out.append(child)
		out.append_array(_all_dirs(child))
	return out
