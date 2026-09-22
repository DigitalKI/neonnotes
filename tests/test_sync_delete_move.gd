extends Node
## Regression test: sync must propagate deletions and folder moves, must NOT let
## a stale copy resurrect a deleted file, and must not permanently tombstone a
## path that is genuinely re-created.
##
## It runs a real SyncService receiver on a dedicated TCP port over loopback and
## pushes carts with the same `SyncService.push_to()` the app uses, so it covers
## the frame protocol, tombstone handling and the sync_changed signal contract
## (count / structure_changed) that drives the receiver's tree refresh.
##
## Disposable user:// vault + suppressed settings writes: it can never touch a
## real vault or settings.cfg. Wired into tests/run_tests.sh.

const PORT := 47899

var _fails := 0
var _events: Array = []
var _result: Dictionary = {}
var _svc: SyncService

func _ready() -> void:
	GameManager.suppress_settings_save = true
	var vault := "user://sync-test-recv"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	GameManager.current_rel = ""
	GameManager.current_file = ""
	GameManager.order.clear()

	# One persistent receiver, like the app's Main-owned SyncService.
	_svc = SyncService.new()
	add_child(_svc)
	_svc.bind_port = PORT
	_svc._broadcasting = true
	_svc.expected_pin = ""
	_svc.set_process(false)
	_svc.sync_changed.connect(func(peer, count, paths, structural):
		_events.append({"peer": peer, "count": count, "paths": paths, "structural": structural}))
	if not GameManager.trusted.has(GameManager.device_id):
		GameManager.add_trusted(GameManager.device_id)
	_svc._poll_server()
	await get_tree().process_frame

	await _case_delete_only()
	await _case_move_folder()
	await _case_move_back()
	await _case_stale_copy_no_resurrect()
	await _case_genuine_recreate()

	print("SYNC DELETE/MOVE RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

# A delete with no other changed files must still count as a structural change,
# otherwise _on_sync_changed never rescans/refreshes the receiver's tree.
func _case_delete_only() -> void:
	GameManager.write_note("Folder/old.md", "---\ntitle: \"Old\"\n---\n\ndoomed\n")
	GameManager.write_note("keep.md", "---\ntitle: \"Keep\"\n---\n\nstays\n")
	GameManager.scan_notes()
	# The unchanged note is older than the receiver's copy, so LWW skips it and
	# only the tombstone lands — exactly the delete-only sync from the app.
	var old_t := FileAccess.get_modified_time(GameManager.vault_abs().path_join("keep.md")) - 5
	_events.clear()
	await _push({
		"keep.md": "---\ntitle: \"Keep\"\n---\n\nstays\n",
		".neonnotes-tombstones.json": JSON.stringify({"Folder/old.md": _now()}),
	}, {"keep.md": old_t})

	_ok(not FileAccess.file_exists(GameManager.vault_abs().path_join("Folder/old.md")), "delete: file removed on receiver")
	var ev := _last_event()
	_ok(ev.get("structural", false), "delete: structural change reported")
	_ok(_has_path(ev, "Folder/old.md"), "delete: tombstoned path listed in changed_paths")

# Moving a folder writes the new paths and tombstones the old ones.
func _case_move_folder() -> void:
	GameManager.write_note("Move me/a.md", "---\ntitle: \"A\"\n---\n\na\n")
	GameManager.write_note("Move me/b.md", "---\ntitle: \"B\"\n---\n\nb\n")
	GameManager.scan_notes()
	_events.clear()
	await _push({
		"Moved-here/a.md": "---\ntitle: \"A\"\n---\n\na\n",
		"Moved-here/b.md": "---\ntitle: \"B\"\n---\n\nb\n",
		".neonnotes-tombstones.json": JSON.stringify({
			"Move me/a.md": _now(),
			"Move me/b.md": _now(),
		}),
	})

	var v := GameManager.vault_abs()
	_ok(FileAccess.file_exists(v.path_join("Moved-here/a.md")), "move: new path created")
	_ok(not FileAccess.file_exists(v.path_join("Move me/a.md")), "move: old path removed")
	_ok(_last_event().get("structural", false), "move: structural change reported")

# A path moved back is re-created newer than the tombstone, so it must win.
func _case_move_back() -> void:
	await get_tree().create_timer(1.1).timeout  # cross the 1 s mtime granularity
	_events.clear()
	await _push({
		"Move me/a.md": "---\ntitle: \"A\"\n---\n\na\n",
		"Move me/b.md": "---\ntitle: \"B\"\n---\n\nb\n",
		".neonnotes-tombstones.json": JSON.stringify({
			"Moved-here/a.md": _now(),
			"Moved-here/b.md": _now(),
		}),
	})
	var v := GameManager.vault_abs()
	_ok(FileAccess.file_exists(v.path_join("Move me/a.md")), "move-back: re-created path accepted")
	_ok(not FileAccess.file_exists(v.path_join("Moved-here/a.md")), "move-back: old path removed")

# Regression (the reported "bounce"): a peer that still holds a stale copy must
# not resurrect a file another device deleted. The stale file's mtime predates
# the tombstone, so the receiver must keep it deleted.
func _case_stale_copy_no_resurrect() -> void:
	GameManager.write_note("Gone.md", "---\ntitle: \"Gone\"\n---\n\nbye\n")
	GameManager.scan_notes()
	# Step 1: the deletion arrives.
	_events.clear()
	await _push({".neonnotes-tombstones.json": JSON.stringify({"Gone.md": _now()})})
	_ok(not FileAccess.file_exists(GameManager.vault_abs().path_join("Gone.md")), "stale: deletion applied")

	# Step 2: a stale copy arrives with an OLDER mtime (as a real peer would
	# re-send it, preserving the original timestamp). Must be rejected.
	var stale_t := _now() - 60
	_events.clear()
	await _push({"Gone.md": "---\ntitle: \"Gone\"\n---\n\nbye\n"}, {"Gone.md": stale_t})
	_ok(not FileAccess.file_exists(GameManager.vault_abs().path_join("Gone.md")), "stale: copy NOT resurrected")
	_ok(_svc._tombstones.has("Gone.md"), "stale: tombstone retained")

# A genuine local re-create is newer than the tombstone and must propagate.
func _case_genuine_recreate() -> void:
	await get_tree().create_timer(1.1).timeout  # cross the 1 s mtime granularity
	_events.clear()
	await _push({"Gone.md": "---\ntitle: \"Gone\"\n---\n\nback\n"}, {"Gone.md": _now()})
	_ok(FileAccess.file_exists(GameManager.vault_abs().path_join("Gone.md")), "recreate: newer file accepted")

func _push(files: Dictionary, custom_times: Dictionary = {}) -> void:
	var times := {}
	for k in files.keys():
		times[k] = custom_times.get(k, _now())
	var t := Thread.new()
	t.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, "", files, 8000, times, "127.0.0.1"))
	var waited := 0
	while t.is_alive() and waited < 6000:
		_svc._poll_server()
		await get_tree().process_frame
		waited += 1
	_svc._poll_server()
	t.wait_to_finish()
	if not _result.get("ok", false):
		_fails += 1
		print("  ✗ push failed: %s" % [_result])
	# Let the receiver observe the peer disconnect and clean up the connection.
	_svc._poll_server()
	_ok(_svc._partial.is_empty(), "connection cleaned up after peer disconnect")

func _now() -> int:
	return int(Time.get_unix_time_from_system())

func _last_event() -> Dictionary:
	return _events[-1] if not _events.is_empty() else {}

func _has_path(ev: Dictionary, path: String) -> bool:
	return (ev.get("paths", []) as Array).has(path)

func _ok(ok: bool, label: String) -> void:
	print(("  ✓ " if ok else "  ✗ ") + label)
	if not ok:
		_fails += 1

func _rm_dir(rel: String) -> void:
	var abs := ProjectSettings.globalize_path(rel)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var d := DirAccess.open(abs)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(abs.path_join(f))
	for sub in d.get_directories():
		_rm_dir(rel.path_join(sub))
	DirAccess.remove_absolute(abs)
