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
	_svc.persist_state = false  # hermetic: never read/write user://sync_state.json
	_svc._broadcasting = true
	_svc.set_process(false)
	_svc.sync_changed.connect(func(peer, count, paths, structural):
		_events.append({"peer": peer, "count": count, "paths": paths, "structural": structural}))
	if not GameManager.trusted.has(GameManager.device_id):
		GameManager.add_trusted(GameManager.device_id)
	_svc._poll_server()
	await get_tree().process_frame

	await _case_pair_auth_and_unchanged()
	await _case_probe_skips_unchanged()
	await _case_state_persistence()
	await _case_explicit_repair_converges()
	await _case_manifest_only_payloads()
	await _case_delete_only()
	await _case_move_folder()
	await _case_move_back()
	await _case_stale_copy_no_resurrect()
	await _case_genuine_recreate()
	await _case_self_trust_dropped()

	print("SYNC DELETE/MOVE RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

# A wrong secret must not authorize transfers; unchanged content needs no payload.
func _case_pair_auth_and_unchanged() -> void:
	var v := GameManager.vault_abs()
	GameManager.write_note("same.md", "---\ntitle: Same\n---\n\nsame\n")
	GameManager.scan_notes()
	var original := GameManager.read_note("same.md")
	var t := FileAccess.get_modified_time(v.path_join("same.md"))
	var bad := Thread.new()
	bad.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, "not-the-secret", {"same.md": "changed"}, 8000, {"same.md": t + 5}))
	while bad.is_alive():
		_svc._poll_server()
		await get_tree().process_frame
	bad.wait_to_finish()
	_ok(not _result.get("ok", false), "pairing: wrong phrase rejected")
	_ok(GameManager.read_note("same.md") == original, "pairing: unauthorized file not written")
	_events.clear()
	await _push({"same.md": original}, {"same.md": t})
	_ok(int(_result.get("count", -1)) == 0, "manifest: unchanged file not transferred")
	_ok(_last_event().get("paths", []).is_empty(), "manifest: no unchanged path reported")
	# Logical mtime is the persisted record when we have one, else the disk mtime.
	# No file contents are read while building or answering a manifest.
	GameManager.write_note("dated.md", "---\ntitle: Dated\n---\n\nbody")
	var inventory := _svc.collect_manifest({}, v, ["dated.md"], {"dated.md": 1234567890})
	_ok(int(inventory["dated.md"]["modified"]) == 1234567890, "manifest: persisted logical mtime wins")
	var disk := FileAccess.get_modified_time(v.path_join("dated.md"))
	_ok(int(_svc.collect_manifest({}, v, ["dated.md"])["dated.md"]["modified"]) == disk, "manifest: falls back to disk mtime")
	var order_path := v.path_join(".neonnotes.json")
	var f := FileAccess.open(order_path, FileAccess.WRITE)
	f.store_string("{\"order\":{},\"collapsed\":{}}")
	f.close()
	_ok(_svc.collect_manifest({}, v, []).has(".neonnotes.json"), "manifest: vault order metadata included")

# The probe handshake: re-sending a content set the receiver already applied
# must skip the manifest and payloads entirely, reporting `already`.
func _case_probe_skips_unchanged() -> void:
	var v := GameManager.vault_abs()
	GameManager.write_note("probe.md", "---\ntitle: Probe\n---\n\nprobe\n")
	GameManager.scan_notes()
	var entries := _svc.collect_manifest({}, v, ["probe.md"])
	entries["probe.md"]["modified"] = _now() + 5  # genuinely newer than our own copy
	var pushed := 0
	for i in 2:
		var thread := Thread.new()
		thread.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, GameManager.vault_secret, {}, 8000, {}, "127.0.0.1", entries, v))
		while thread.is_alive():
			_svc._poll_server()
			await get_tree().process_frame
		thread.wait_to_finish()
		_ok(_result.get("ok", false), "probe: push %d succeeded" % [i + 1])
		if i == 0:
			pushed = int(_result.get("count", 0))
		else:
			_ok(_result.get("already", false) and int(_result.get("count", 0)) == 0,
				"probe: identical state skipped without transfer")
	_ok(pushed == 1, "probe: first push delivered the file")
	# A local edit changes the fingerprint, so the next probe is not skipped.
	entries["probe.md"]["modified"] = _now() + 9
	var thread2 := Thread.new()
	thread2.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, GameManager.vault_secret, {}, 8000, {}, "127.0.0.1", entries, v))
	while thread2.is_alive():
		_svc._poll_server()
		await get_tree().process_frame
	thread2.wait_to_finish()
	_ok(not _result.get("already", false) and int(_result.get("count", 0)) == 1,
		"probe: changed state is re-sent")

# Logical mtimes, tombstones and confirmed fingerprints must survive a restart,
# or a received media file would be restamped on receipt and look newer forever.
func _case_state_persistence() -> void:
	var file := "user://sync-test-state.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	var svc := SyncService.new()
	svc.persist_state = true
	svc.state_file_override = file
	svc._ensure_state_loaded()
	svc._mtimes["roundtrip.md"] = 12345
	svc._tombstones["gone.md"] = 999
	svc._confirmed["peer-x"] = "deadbeef"
	svc._save_state()
	# A fresh instance is a restart: it must reload the same vault's state.
	var svc2 := SyncService.new()
	svc2.persist_state = true
	svc2.state_file_override = file
	svc2._ensure_state_loaded()
	_ok(int(svc2._mtimes.get("roundtrip.md", 0)) == 12345, "state: logical mtimes persist across restart")
	_ok(int(svc2._tombstones.get("gone.md", 0)) == 999, "state: tombstones persist across restart")
	_ok(str(svc2._confirmed.get("peer-x", "")) == "deadbeef", "state: confirmed fingerprints persist")
	_ok(SyncService.state_fingerprint({"a.md": {"modified": 1, "size": 2}}) == SyncService.state_fingerprint({"a.md": {"modified": 1, "size": 2}}), "state: fingerprint is deterministic")
	_ok(SyncService.state_fingerprint({"a.md": {"modified": 1, "size": 2}}) != SyncService.state_fingerprint({"a.md": {"modified": 2, "size": 2}}), "state: fingerprint tracks mtime")
	# A non-empty tombstone set must not make collect_manifest() time-dependent:
	# a "now" timestamp there defeats `_confirmed` on every sync, forcing a full
	# manifest each time and a per-file read on the receiver (the mobile freeze).
	var v := GameManager.vault_abs()
	GameManager.write_note("stable.md", "---\ntitle: Stable\n---\n\nbody\n")
	GameManager.scan_notes()
	var m1 := _svc.collect_manifest({"gone.md": 111}, v, ["stable.md"])
	var m2 := _svc.collect_manifest({"gone.md": 111}, v, ["stable.md"])
	_ok(SyncService.state_fingerprint(m1) == SyncService.state_fingerprint(m2), "state: tombstone fingerprint is stable")
	var m3 := _svc.collect_manifest({"gone.md": 222}, v, ["stable.md"])
	_ok(SyncService.state_fingerprint(m1) != SyncService.state_fingerprint(m3), "state: tombstone fingerprint tracks content")
	svc.free()
	svc2.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))  # never the app's real state

# Two devices that were paired under different phrases converge only when the
# user explicitly re-enters the receiver's phrase; a routine sync never repoints
# local identity.
func _case_explicit_repair_converges() -> void:
	var orig_secret := GameManager.vault_secret
	var orig_vault_id := GameManager.vault_id
	var orig_paired := GameManager.paired_vault_id
	var orig_trusted := GameManager.trusted.duplicate()
	var orig_peers := GameManager.paired_peers.duplicate(true)
	var pid := "peer-converge-test"
	GameManager.vault_secret = "phrase-a"
	GameManager.vault_id = "vault-a"
	if not GameManager.trusted.has(pid):
		GameManager.add_trusted(pid)
	# Routine auto-sync must not repoint identity.
	SyncService.accept_pair({"ok": true, "peer_id": pid, "vault_id": "vault-b", "secret": "phrase-b", "peer_name": "Peer", "ip": "10.0.0.1"}, false)
	_ok(GameManager.vault_secret == "phrase-a", "pairing: routine sync keeps local vault identity")
	# Explicit re-pair adopts the receiver's phrase (and vault id).
	SyncService.accept_pair({"ok": true, "peer_id": pid, "vault_id": "vault-b", "secret": "phrase-b", "peer_name": "Peer", "ip": "10.0.0.1"}, true)
	_ok(GameManager.vault_secret == "phrase-b" and GameManager.vault_id == "vault-b", "pairing: explicit re-pair adopts receiver phrase + vault id")
	_ok(str(GameManager.paired_peers.get(pid, {}).get("phrase", "")) == "phrase-b", "pairing: peer phrase recorded for future syncs")
	GameManager.vault_secret = orig_secret
	GameManager.vault_id = orig_vault_id
	GameManager.paired_vault_id = orig_paired
	GameManager.trusted = orig_trusted
	GameManager.paired_peers = orig_peers

# A device must never remain its own peer (UDP loopback + same-device instances).
func _case_self_trust_dropped() -> void:
	GameManager.add_trusted(GameManager.device_id)
	GameManager.paired_peers[GameManager.device_id] = {"ip": "127.0.0.1", "name": "self"}
	GameManager._drop_self_trust()
	_ok(not GameManager.trusted.has(GameManager.device_id), "pairing: self trust dropped")
	_ok(not GameManager.paired_peers.has(GameManager.device_id), "pairing: self peer entry dropped")

# Inventory-only transfer must lazily read just the paths requested by the
# receiver. A newer logical mtime is requested; equal mtime means in-sync.
func _case_manifest_only_payloads() -> void:
	var vault := GameManager.vault_abs()
	GameManager.write_note("delta.md", "changed contents")
	GameManager.scan_notes()
	var entries := _svc.collect_manifest({}, vault, ["delta.md"])
	_ok(entries.has("delta.md") and int(entries["delta.md"]["size"]) == "changed contents".to_utf8_buffer().size(), "manifest: inventory has byte length")
	# The inventory carries no payload. Force a newer version so it is
	# requested, then confirm the worker reads the file and writes it.
	entries["delta.md"]["modified"] = _now() + 5
	var thread := Thread.new()
	thread.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, GameManager.vault_secret, {}, 8000, {}, "127.0.0.1", entries, vault))
	while thread.is_alive():
		_svc._poll_server()
		await get_tree().process_frame
	thread.wait_to_finish()
	_ok(_result.get("ok", false) and int(_result.get("count", 0)) == 1, "manifest: requested payload read lazily")
	_ok(GameManager.read_note("delta.md") == "changed contents", "manifest: receiver wrote requested file")

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
	t.start(func(): _result = SyncService.push_to("127.0.0.1", PORT, GameManager.vault_secret, files, 8000, times, "127.0.0.1"))
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
