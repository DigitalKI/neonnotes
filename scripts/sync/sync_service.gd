class_name SyncService
extends Node

signal peers_changed
signal sync_done(peer_name: String, count: int)
signal sync_changed(peer_name: String, count: int, changed_paths: Array, structure_changed: bool)
signal sync_failed(reason: String)
signal sync_pending

const DISCOVERY_PORT := 47770
const TCP_PORT := 47771
const BROADCAST_INTERVAL := 2.0
const PEER_TIMEOUT := 6.0
const MAGIC := "neonnotes-v2"

const WORDS := [
	"acid", "amber", "anchor", "apple", "arrow", "atlas", "aurora", "axis",
	"balloon", "basin", "beam", "bingo", "bishop", "blade", "bloom", "bolt",
	"cargo", "cedar", "chalk", "cherry", "cobra", "comet", "coral", "crane",
	"daisy", "delta", "denim", "domino", "drift", "ember", "eagle", "echo",
	"falcon", "fable", "fern", "flint", "forge", "frost", "gadget", "garnet",
	"gecko", "glide", "granite", "harbor", "helix", "husky", "ivory", "jade",
	"joker", "kayak", "laser", "lemon", "lunar", "maple", "meteor", "nebula",
	"onyx", "orbit", "pixel", "quartz", "raven", "sonic", "tiger", "vapor",
]

var peers: Dictionary = {}
var device_name: String = ""

## Eight random words (48 bits); never broadcast this secret.
static func gen_vault_secret() -> String:
	var bytes := Crypto.new().generate_random_bytes(8)
	var words: Array[String] = []
	for b in bytes:
		words.append(WORDS[int(b) % WORDS.size()])
	return "-".join(words)

var _pending_unsynced := false
var _change_generation := 0

## Stable 4-word identity code (17.8M space) — the human-readable device ID.
static func gen_device_code() -> String:
	var out := []
	for i in 4:
		out.append(WORDS[randi() % WORDS.size()])
	return "-".join(out)

var _udp: PacketPeerUDP
var _server: TCPServer
var _bcast_timer: Timer
var _cleanup_timer: Timer
var _broadcasting := false
## TCP port to listen on. Defaults to the LAN sync port; overridable so tests
## and ad-hoc harnesses can run a receiver without clashing with a live app.
var bind_port := TCP_PORT
var _partial: Dictionary = {}  # peer_id -> {"buf": PackedByteArray}

func _ready() -> void:
	var env := OS.get_environment("NEONNOTES_DEVICE")
	if env != "":
		device_name = env
	else:
		# stable name derived from the persistent device word-code
		device_name = "%s-%04d" % [OS.get_name(), abs(int(GameManager.device_id.hash()) % 10000)]

# ---------------- Discovery ----------------

func start_discovery() -> bool:
	# Hard gate: an ephemeral test/dev session (suppress_settings_save) must not
	# join the LAN. It shares the real vault id/secret, so announcing or listening
	# would let a fixture vault sync test notes to the user's real peers.
	if GameManager.suppress_settings_save:
		return false
	stop_discovery()
	# Keep discovery alive even when this dialog is closed; Main owns this node.
	set_process(true)
	_udp = PacketPeerUDP.new()
	if _udp.bind(DISCOVERY_PORT) != OK:
		_udp = null
		return false
	_udp.set_broadcast_enabled(true)
	_broadcasting = true
	_bcast_timer = Timer.new()
	_bcast_timer.name = "BcastTimer"
	_bcast_timer.wait_time = BROADCAST_INTERVAL
	_bcast_timer.timeout.connect(_send_broadcast)
	add_child(_bcast_timer)
	_bcast_timer.start()
	_send_broadcast()
	_cleanup_timer = Timer.new()
	_cleanup_timer.name = "CleanupTimer"
	_cleanup_timer.wait_time = 2.0
	_cleanup_timer.timeout.connect(_expire_peers)
	add_child(_cleanup_timer)
	_cleanup_timer.start()
	return true

func stop_discovery() -> void:
	_broadcasting = false
	if _server and _server.is_listening():
		_server.stop()  # release the TCP port when sync is off
	if _bcast_timer:
		_bcast_timer.stop()
		_bcast_timer.queue_free()
		_bcast_timer = null
	if _cleanup_timer:
		_cleanup_timer.stop()
		_cleanup_timer.queue_free()
		_cleanup_timer = null
	if _udp:
		_udp.close()
		_udp = null
	if peers.size() > 0:
		peers.clear()
		peers_changed.emit()

func _send_broadcast() -> void:
	if _udp == null:
		return
	var msg := JSON.stringify({"proto": MAGIC, "name": device_name, "id": GameManager.device_id, "vault_id": GameManager.vault_id, "tcp": TCP_PORT})
	_udp.set_broadcast_enabled(true)
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_udp.put_packet(msg.to_utf8_buffer())

func _expire_peers() -> void:
	var now := Time.get_ticks_msec()
	var changed := false
	for ip in peers.keys():
		if now - int(peers[ip]["seen"]) > int(PEER_TIMEOUT * 1000.0):
			peers.erase(ip)
			changed = true
	if changed:
		peers_changed.emit()

func _process(_delta: float) -> void:
	# Stall detector: a frame that takes far longer than usual is logged with the
	# sync state at that moment, so a freeze can be tied to a sync phase instead
	# of guessed at. Only active with debug logging.
	if debug_log:
		var now_ms := Time.get_ticks_msec()
		if _last_frame_ms > 0:
			var gap := now_ms - _last_frame_ms
			if gap > 400:
				_sync_log("STALL main thread %d ms (syncing=%s)" % [gap, str(_syncing)])
		_last_frame_ms = now_ms
	_poll_thread_result()
	_poll_discovery()
	_poll_server()

func _poll_thread_result() -> void:
	if _sync_thread == null:
		return
	_sync_mutex.lock()
	var result: Dictionary = _sync_result.pop_front() if not _sync_result.is_empty() else {}
	_sync_mutex.unlock()
	if result.is_empty():
		return
	_sync_thread.wait_to_finish()
	_sync_thread = null
	_syncing = false
	if result.get("ok", false):
		for pair in result.get("pairs", []):
			accept_pair(pair)
		if int(result.get("generation", -1)) == _change_generation and int(result.get("failures", 0)) == 0:
			_pending_unsynced = false
		sync_done.emit(str(result.get("name", "peer")), int(result.get("count", 0)))
	else:
		sync_failed.emit(str(result.get("error", "sync failed")))

func _poll_discovery() -> void:
	if _udp == null:
		return
	while _udp.get_available_packet_count() > 0:
		var raw := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		if ip == "" or ip == "255.255.255.255":
			continue
		var data = JSON.parse_string(raw.get_string_from_utf8())
		if typeof(data) != TYPE_DICTIONARY or data.get("proto", "") != MAGIC:
			continue
		# UDP broadcast loops back to us: a peer claiming our own device id is
		# this device. Never list or target it.
		if str(data.get("id", "")) == GameManager.device_id:
			continue
		var now := Time.get_ticks_msec()
		if not peers.has(ip):
			peers[ip] = {"name": str(data.get("name", "peer")), "id": str(data.get("id", "")), "vault_id": str(data.get("vault_id", "")), "tcp": int(data.get("tcp", TCP_PORT)), "seen": now}
			peers_changed.emit()
		else:
			peers[ip]["seen"] = now
			peers[ip]["name"] = str(data.get("name", peers[ip]["name"]))
			peers[ip]["id"] = str(data.get("id", peers[ip].get("id", "")))
			peers[ip]["vault_id"] = str(data.get("vault_id", peers[ip].get("vault_id", "")))

# ---------------- TCP listener ----------------

func _ensure_server() -> bool:
	if _server and _server.is_listening():
		return true
	if not _broadcasting:
		return false  # sync not active — don't bind ports in the background
	_server = TCPServer.new()
	# "*" is Godot's portable all-interface bind address. Some mobile
	# platforms reject the literal 0.0.0.0 here even though desktop accepts it.
	var err := _server.listen(bind_port, "*")
	if err != OK:
		_server = null
		if not _tcp_error_reported:
			_tcp_error_reported = true
			sync_failed.emit("Could not open TCP port %d (error %s). Check firewall or another NeonNotes instance." % [TCP_PORT, error_string(err)])
		return false
	_tcp_error_reported = false
	return true

func _poll_server() -> void:
	if not _ensure_server():
		return
	_ensure_state_loaded()
	while _server.is_connection_available():
		var conn: StreamPeerTCP = _server.take_connection()
		_partial[conn.get_instance_id()] = {"conn": conn, "buf": PackedByteArray(), "paired": false}
		_sync_log("IN accept from=%s" % conn.get_connected_host())
	var done_ids := []
	for id in _partial.keys():
		var st: Dictionary = _partial[id]
		var conn: StreamPeerTCP = st["conn"]
		conn.poll()
		var status := conn.get_status()
		# A peer that closes cleanly leaves status NONE (not ERROR), so the old
		# ERROR-only check never cleaned it up: get_available_bytes() then spams
		# `Condition "!is_open()" is true` every frame and the entry leaks in
		# _partial. Drop closed/errored connections here.
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			conn.disconnect_from_host()
			done_ids.append(id)
			continue
		if conn.get_available_bytes() > 0:
			# Cap socket work per frame. Large media frames can arrive over many
			# frames without freezing navigation while the network is busy.
			st["buf"] = st["buf"] + conn.get_data(mini(conn.get_available_bytes(), 65536))[1]
		# Try to parse framed messages
		var buf: PackedByteArray = st["buf"]
		while buf.size() >= 4:
			var length := buf.decode_u32(0)
			# Allow large sync carts: vault media is embedded as base64 in a single
			# frame, which can be tens of MB. 256 MB is ample for a whole vault.
			if length > 256 * 1024 * 1024:
				conn.disconnect_from_host()
				done_ids.append(id)
				break
			if buf.size() < 4 + length:
				break
			var msg_bytes := buf.slice(4, 4 + length)
			buf = buf.slice(4 + length)
			st["buf"] = buf
			var msg = JSON.parse_string(msg_bytes.get_string_from_utf8())
			if typeof(msg) != TYPE_DICTIONARY:
				_send_json(conn, {"ok": false, "error": "bad_message"})
				conn.disconnect_from_host()
				done_ids.append(id)
				break
			var reply := _handle_message(conn, msg, st, conn.get_connected_host())
			if not st.get("no_reply", false):
				_sync_log("IN reply cmd=%s ok=%s" % [String(msg.get("cmd", "")), str(reply.get("ok", false))])
				_send_json(conn, reply)
			st["no_reply"] = false
			if not st.get("paired", false) and (String(msg.get("cmd", "")) != "pair_hello" or not reply.get("ok", false)):
				# Unauthenticated: the challenge is the only command allowed
				# before the proof; failed proofs close this socket.
				conn.disconnect_from_host()
				done_ids.append(id)
				break
			var was_legacy_push := String(msg.get("cmd", "")) == "push"
			if was_legacy_push:
				conn.disconnect_from_host()
				done_ids.append(id)
				break
			# Streaming batches keep the connection open until push_end arrives.
			# Parse at most one complete frame per UI frame.
			break
		if done_ids.has(id):
			continue
	for id in done_ids:
		_partial.erase(id)

func _handle_message(conn: StreamPeerTCP, msg: Dictionary, st: Dictionary, peer_ip := "") -> Dictionary:
	var cmd := String(msg.get("cmd", ""))
	_sync_log("IN recv cmd=%s id=%s ip=%s" % [cmd, str(msg.get("id", "")), peer_ip])
	if cmd == "pair_hello":
		var client_nonce := str(msg.get("nonce", ""))
		if client_nonce.length() != 32:
			return {"ok": false, "error": "auth"}
		st["challenge"] = Crypto.new().generate_random_bytes(16).hex_encode()
		st["client_nonce"] = client_nonce
		return {"ok": true, "challenge": st["challenge"]}
	if cmd == "pair":
		var sender_id := String(msg.get("id", ""))
		var challenge := str(st.get("challenge", ""))
		var client_nonce := str(st.get("client_nonce", ""))
		var secret_ok := false
		var matched_phrase := ""
		for candidate in [GameManager.vault_secret, str(GameManager.paired_peers.get(sender_id, {}).get("phrase", ""))]:
			if candidate == "" or challenge == "" or client_nonce == "":
				continue
			if str(msg.get("proof", "")) == _secret_proof(candidate, challenge + client_nonce):
				secret_ok = true
				matched_phrase = candidate
				break
		st.erase("challenge")
		st.erase("client_nonce")
		if sender_id == "" or not secret_ok:
			return {"ok": false, "error": "auth"}
		st["paired"] = true
		st["peer_id"] = sender_id
		# Record the sender's IP so our own auto-sync can connect back to them
		# even when broadcast discovery is asymmetrical (mobile's UDP listener
		# often isn't reached by LAN broadcasts, but TCP reverse-connect works).
		st["peer_ip"] = peer_ip
		st["peer_phrase"] = matched_phrase
		return {"ok": true, "name": device_name, "id": GameManager.device_id, "vault_id": GameManager.vault_id, "proof": _secret_proof(matched_phrase, client_nonce + challenge)}
	if cmd == "probe":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		var probe_peer := String(msg.get("id", ""))
		var probe_state := str(msg.get("state", ""))
		var already := probe_peer != "" and probe_state != "" and str(_confirmed.get(probe_peer, "")) == probe_state
		_sync_log("IN probe peer=%s already=%s" % [probe_peer, already])
		return {"ok": true, "already": already}
	if cmd == "manifest":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		var entries = msg.get("entries", {})
		if typeof(entries) != TYPE_DICTIONARY or entries.size() > 50000:
			return {"ok": false, "error": "bad_manifest"}
		var manifest_start := Time.get_ticks_msec()
		var needed: Array[String] = []
		var vault := GameManager.vault_abs()
		for path in entries:
			var name := str(path)
			if not _valid_sync_path(name):
				continue
			var remote: Dictionary = entries[path] if typeof(entries[path]) == TYPE_DICTIONARY else {}
			if name == ".neonnotes-tombstones.json":
				# Deletions are idempotent; send them until peers have seen them.
				needed.append(name)
				continue
			var remote_t := int(remote.get("modified", 0))
			if int(_tombstones.get(name, -1)) >= remote_t:
				continue
			var local := vault.path_join(name)
			if not FileAccess.file_exists(local):
				needed.append(name)
				continue
			var local_t := _file_logical_time(local, name, _mtimes)
			# Trust the logical mtime: equal means the same write event, so the
			# receiver already holds this version. Deliberately no per-file open
			# here — this handler runs on the main thread and opening every
			# unchanged file (hundreds of files) froze the UI on mobile.
			if remote_t > local_t:
				needed.append(name)
		_sync_log("IN manifest entries=%d needed=%d took=%d ms" % [entries.size(), needed.size(), Time.get_ticks_msec() - manifest_start])
		return {"ok": true, "needed": needed}
	if cmd == "push_stream":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		var stream_id := str(st.get("peer_id", ""))
		st["batch_peer_id"] = stream_id
		st["batch_peer_name"] = str(msg.get("name", stream_id))
		st["peer_state"] = str(msg.get("state", ""))
		st["pending"] = int(msg.get("pending", 0))
		st["stream_active"] = true
		st["count"] = 0
		st["deleted"] = 0
		st["deleted_paths"] = []
		st["changed_paths"] = []
		# Fire-and-forget: the client streams items right away and only reads
		# the terminal push_end ack. Replying here would sit unread in the
		# client's buffer and be mistaken for the push_end reply (count 0).
		st["no_reply"] = true
		_sync_log("IN stream begin peer=%s pending=%d" % [st["batch_peer_name"], st["pending"]])
		return {"ok": true, "expected": int(st.get("pending", 0))}
	if cmd == "push_item":
		if not st.get("paired", false) or not st.get("stream_active", false):
			return {"ok": false, "error": "auth"}
		st["no_reply"] = true
		_receive_item(st, msg)
		return {}
	if cmd == "push_end":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		if not st.get("stream_active", false):
			return {"ok": false, "error": "no_stream"}
		st["stream_active"] = false
		var stream_summary := _finish_stream(st)
		_sync_log("IN stream done peer=%s wrote=%d" % [st.get("batch_peer_name", "peer"), stream_summary.get("count", 0)])
		var stream_ok: bool = stream_summary.get("ok", false)
		return {"ok": stream_ok, "count": int(stream_summary.get("count", 0)), "summary": stream_summary}
	if cmd == "push":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		var files = msg.get("files", {})
		if typeof(files) != TYPE_DICTIONARY:
			return {"ok": false, "error": "bad_files"}
		var times = msg.get("times", {})
		if typeof(times) != TYPE_DICTIONARY:
			times = {}
		var count := 0
		var changed_paths: Array[String] = []
		var deleted := 0
		var skipped := 0
		var invalid := 0
		var vault := GameManager.vault_abs()
		_sync_log("IN start peer=%s files=%d" % [str(msg.get("name", "peer")), files.size()])
		if vault == "":
			return {"ok": false, "error": "no_vault"}
		for fname in files.keys():
			var name := String(fname)
			# allow subfolders; reject traversal/absolute paths and exports
			if name == "" or name.begins_with("/") or name.contains("\\") or name.contains("..") \
					or name.get_base_dir() == GameManager.EXPORTS_SUBDIR:
				invalid += 1
				_sync_log("IN invalid path=%s" % name)
				continue
			var dest := vault.path_join(name)
			var text := String(files[fname])
			if name == ".neonnotes-tombstones.json":
				var remote_tombs = JSON.parse_string(text)
				if typeof(remote_tombs) == TYPE_DICTIONARY:
					for deleted_path in remote_tombs.keys():
						if not _valid_sync_path(str(deleted_path)) or int(remote_tombs[deleted_path]) < int(_tombstones.get(str(deleted_path), -1)):
							continue
						var deleted_file := vault.path_join(str(deleted_path))
						if FileAccess.file_exists(deleted_file) and _file_logical_time(deleted_file, str(deleted_path), _mtimes) <= int(remote_tombs[deleted_path]):
							DirAccess.remove_absolute(deleted_file)
							deleted += 1
							changed_paths.append(str(deleted_path))
						if not FileAccess.file_exists(deleted_file):
							_tombstones[str(deleted_path)] = remote_tombs[deleted_path]
						continue
			var remote_t := int(times.get(fname, 0))
			if _tombstones.has(name):
				# A tombstone only blocks a copy that predates the deletion; a
				# newer file is a legitimate recreation and must win.
				if int(_tombstones[name]) >= remote_t:
					skipped += 1
					_sync_log("IN tombstone-skip path=%s" % name)
					continue
				_tombstones.erase(name)
			var binary := not name.ends_with(".md") and not name.ends_with(".json")
			# last-writer-wins: skip if our local copy is strictly newer
			if FileAccess.file_exists(dest) and times.has(fname):
				var local_t := _file_logical_time(dest, name, _mtimes)
				if local_t > remote_t:
					skipped += 1
					_sync_log("IN newer-local path=%s local=%d remote=%d" % [name, local_t, remote_t])
					continue
			DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
			if binary:
				var raw := Marshalls.base64_to_raw(text)
				if raw.is_empty() and FileAccess.file_exists(dest):
					skipped += 1
					_sync_log("IN skip-empty-binary path=%s" % name)
					continue
			var f := FileAccess.open(dest, FileAccess.WRITE)
			if f == null:
				skipped += 1
				_sync_log("IN open-failed path=%s" % name)
				continue
			if binary:
				f.store_buffer(Marshalls.base64_to_raw(text))
			else:
				f.store_string(text)
			f.close()
			_mtimes[name] = remote_t
			count += 1
			changed_paths.append(name)
			_sync_log("IN wrote path=%s bytes=%d" % [name, text.to_utf8_buffer().size()])
		_sync_log("IN done peer=%s wrote=%d deleted=%d skipped=%d invalid=%d" % [str(msg.get("name", "peer")), count, deleted, skipped, invalid])
		var legacy_note_change := deleted > 0
		if not legacy_note_change:
			for p in changed_paths:
				var ps := String(p)
				if ps.ends_with(".md") or ps.ends_with(".json"):
					legacy_note_change = true
					break
		if legacy_note_change:
			GameManager.scan_notes()
		var peer_id := String(st.get("peer_id", ""))
		if peer_id != "":
			GameManager.add_trusted(peer_id)  # successfully paired+pushed → remember
			enable_auto_sync()
		var structural := deleted > 0
		for p in changed_paths:
			if String(p).ends_with(".md") or String(p).get_base_dir() != "":
				structural = true
				break
		var total := count + deleted
		if peer_id != "" and str(st.get("peer_ip", "")) != "":
			var rec: Dictionary = GameManager.paired_peers.get(peer_id, {})
			rec["name"] = str(msg.get("name", peer_id))
			rec["vault_id"] = GameManager.vault_id
			rec["ip"] = str(st["peer_ip"])
			rec["phrase"] = str(st.get("peer_phrase", ""))
			GameManager.paired_peers[peer_id] = rec
			GameManager._save_settings()
		sync_done.emit(str(msg.get("name", "peer")), total)
		sync_changed.emit(str(msg.get("name", "peer")), total, changed_paths, structural)
		return {"ok": true, "count": total}
	return {"ok": false, "error": "unknown_cmd"}

# ---------------- Stream receive (bounded memory) ----------------

static func _valid_sync_path(name: String) -> bool:
	# The Trash is device-local (trash never syncs); deletes still propagate as
	# tombstones, so a peer is never sent recoverable copies of deleted files.
	if name == NoteCrud.TRASH_DIR or name.begins_with(NoteCrud.TRASH_DIR + "/"):
		return false
	return name != "" and not name.begins_with("/") and not name.contains("\\") and not name.contains("..") and name.get_base_dir() != GameManager.EXPORTS_SUBDIR

static func _secret_proof(secret: String, nonce: String) -> String:
	return ("neonnotes-pair:" + secret + ":" + nonce).sha256_text()

func _receive_item(st: Dictionary, msg: Dictionary) -> void:
	var name := String(msg.get("name", ""))
	# allow subfolders; reject traversal/absolute paths and exports
	if name == "" or name.begins_with("/") or name.contains("\\") or name.contains("..") \
			or name.get_base_dir() == GameManager.EXPORTS_SUBDIR:
		st["invalid"] = int(st.get("invalid", 0)) + 1
		_sync_log("IN invalid path=%s" % name)
		return
	var text := String(msg.get("text", ""))
	if name == ".neonnotes-tombstones.json":
		var remote_tombs = JSON.parse_string(text)
		if typeof(remote_tombs) == TYPE_DICTIONARY:
			var vault := GameManager.vault_abs()
			var deleted_paths: Array = st.get("deleted_paths", [])
			for deleted_path in remote_tombs.keys():
				if not _valid_sync_path(str(deleted_path)) or int(remote_tombs[deleted_path]) < int(_tombstones.get(str(deleted_path), -1)):
					continue
				var deleted_file := vault.path_join(str(deleted_path))
				if FileAccess.file_exists(deleted_file) and _file_logical_time(deleted_file, str(deleted_path), _mtimes) <= int(remote_tombs[deleted_path]):
					DirAccess.remove_absolute(deleted_file)
					deleted_paths.append(str(deleted_path))
				if not FileAccess.file_exists(deleted_file):
					_tombstones[str(deleted_path)] = remote_tombs[deleted_path]
			st["deleted_paths"] = deleted_paths
			st["deleted"] = deleted_paths.size()
		return
	var remote_t := int(msg.get("modified", 0))
	if _tombstones.has(name):
		# A tombstone only blocks a copy that predates the deletion. A file
		# modified AFTER the tombstone is a legitimate recreation (e.g. a
		# folder moved back, or a deleted note re-created) and must win.
		if int(_tombstones[name]) >= remote_t:
			st["skipped"] = int(st.get("skipped", 0)) + 1
			_sync_log("IN tombstone-skip path=%s" % name)
			return
		_tombstones.erase(name)
	var vault := GameManager.vault_abs()
	if vault == "":
		return
	var dest := vault.path_join(name)
	if FileAccess.file_exists(dest) and remote_t > 0:
		var local_t := _file_logical_time(dest, name, _mtimes)
		# Logical mtime is authoritative (LWW): an equal-or-newer local copy wins.
		# No per-file open for a size tiebreak — this runs on the main thread.
		if local_t >= remote_t:
			st["skipped"] = int(st.get("skipped", 0)) + 1
			_sync_log("IN newer-local path=%s local=%d remote=%d" % [name, local_t, remote_t])
			return
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var is_bin := bool(msg.get("binary", false))
	var raw := Marshalls.base64_to_raw(text) if is_bin else PackedByteArray()
	# Guard: an empty/truncated binary transfer must never destroy a good local
	# file (this turned a synced image into a 0-byte file that then won't render).
	if is_bin and raw.is_empty() and FileAccess.file_exists(dest):
		st["skipped"] = int(st.get("skipped", 0)) + 1
		_sync_log("IN skip-empty-binary path=%s" % name)
		return
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		st["skipped"] = int(st.get("skipped", 0)) + 1
		_sync_log("IN open-failed path=%s" % name)
		return
	if is_bin:
		f.store_buffer(raw)
	else:
		f.store_string(text)
	f.close()
	# Remember the sender's timestamp: re-sending this file must not look newer
	# than an older tombstone just because receipt stamped it with our clock.
	_mtimes[name] = remote_t
	st["count"] = int(st.get("count", 0)) + 1
	var changed: Array = st.get("changed_paths", [])
	changed.append(name)
	st["changed_paths"] = changed
	_sync_log("IN wrote path=%s bytes=%d" % [name, text.to_utf8_buffer().size()])

func _finish_stream(st: Dictionary) -> Dictionary:
	var wrote := int(st.get("count", 0))
	var deleted_paths: Array = st.get("deleted_paths", [])
	var deleted := deleted_paths.size()
	var changed_paths: Array = st.get("changed_paths", [])
	var vault := GameManager.vault_abs()
	# Rescan only when notes/structure changed. Deletions always need it; a
	# media-only transfer does not (the tree/link index are note-based), and a
	# full vault rescan on the main thread was a multi-second freeze on mobile.
	var need_scan := deleted > 0
	if not need_scan:
		for p in changed_paths:
			var ps := String(p)
			if ps.ends_with(".md") or ps.ends_with(".json"):
				need_scan = true
				break
	if need_scan and vault != "":
		var scan_start := Time.get_ticks_msec()
		GameManager.scan_notes()
		_sync_log("IN rescan dims=%d took=%d ms" % [GameManager.notes.size(), Time.get_ticks_msec() - scan_start])
	var peer_id := String(st.get("batch_peer_id", ""))
	# The batch finished: we now hold the peer's declared content fingerprint, so
	# the next probe from it can be skipped wholesale.
	if peer_id != "" and str(st.get("peer_state", "")) != "":
		_confirmed[peer_id] = str(st["peer_state"])
		_mark_state_dirty()
	# A device is never its own peer: ignore a self-declared id (loopback/test).
	if peer_id != "" and peer_id != GameManager.device_id and vault != "":
		GameManager.add_trusted(peer_id)
		if str(st.get("peer_ip", "")) != "":
			GameManager.paired_peers[peer_id] = {"name": str(st.get("batch_peer_name", peer_id)),
				"vault_id": GameManager.vault_id, "ip": str(st["peer_ip"])}
			GameManager._save_settings()
		enable_auto_sync()  # receiver can send its newer/missing notes back
	# A tombstone deletion is a structural change even if its path is a folder
	# companion (no ".md" and no parent folder in the path).
	var structural := deleted > 0
	for p in changed_paths:
		if String(p).ends_with(".md") or String(p).get_base_dir() != "":
			structural = true
			break
	var all_paths: Array = changed_paths.duplicate()
	for p in deleted_paths:
		if not all_paths.has(p):
			all_paths.append(p)
	var total := wrote + deleted
	sync_done.emit(str(st.get("batch_peer_name", "peer")), total)
	sync_changed.emit(str(st.get("batch_peer_name", "peer")), total, all_paths, structural)
	return {"ok": true, "count": total, "written": wrote, "deleted": deleted, "skipped": int(st.get("skipped", 0)), "invalid": int(st.get("invalid", 0))}

func _send_json(conn: StreamPeerTCP, data: Dictionary) -> void:
	_send_frame_bytes(conn, JSON.stringify(data).to_utf8_buffer())

static func _send_frame(conn: StreamPeerTCP, data: Dictionary) -> void:
	_send_frame_bytes(conn, JSON.stringify(data).to_utf8_buffer())

static func _send_frame_bytes(conn: StreamPeerTCP, bytes: PackedByteArray) -> void:
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, bytes.size())
	frame.append_array(bytes)
	conn.put_data(frame)

# ---------------- Client ----------------

static func push_to(ip: String, port: int, secret: String, files: Dictionary, timeout_ms := 4000, times: Dictionary = {}, peer_ip := "", inventory: Dictionary = {}, vault := "", client_id := "", client_name := "") -> Dictionary:
	var conn := StreamPeerTCP.new()
	var err := conn.connect_to_host(ip, port)
	if err != OK:
		return {"ok": false, "error": "connect_failed"}
	var start := Time.get_ticks_msec()
	while conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		conn.poll()
		OS.delay_msec(1)  # yield: a busy poll loop here starved the UI on mobile
		if conn.get_status() == StreamPeerTCP.STATUS_ERROR or Time.get_ticks_msec() - start > timeout_ms:
			return {"ok": false, "error": "timeout"}
	if client_id == "":
		client_id = GameManager.device_id  # compatibility for direct callers/tests
	if client_name == "":
		client_name = device_display_name()
	var nonce := str(Crypto.new().generate_random_bytes(16).hex_encode())
	var hello: Variant = _client_roundtrip(conn, {"cmd": "pair_hello", "nonce": nonce})
	if typeof(hello) != TYPE_DICTIONARY or not hello.get("ok", false):
		conn.disconnect_from_host()
		return {"ok": false, "error": "challenge_failed"}
	var challenge := str(hello.get("challenge", ""))
	if challenge.length() != 32:
		conn.disconnect_from_host()
		return {"ok": false, "error": "challenge_failed"}
	var reply: Variant = _client_roundtrip(conn, {"cmd": "pair", "proof": _secret_proof(secret, challenge + nonce), "id": client_id})
	if typeof(reply) != TYPE_DICTIONARY or not reply.get("ok", false):
		conn.disconnect_from_host()
		return {"ok": false, "error": str(reply.get("error", "auth")) if typeof(reply) == TYPE_DICTIONARY else "bad_reply"}
	# On first pair, verify that the receiver also knows the secret before trusting it.
	var peer_id := String(reply.get("id", ""))
	if secret == "" or str(reply.get("proof", "")) != _secret_proof(secret, nonce + challenge):
		# A trusted peer with its own recorded phrase (different vault era) is
		# still authentic if it proves with that phrase.
		var peer_phrase := str(GameManager.paired_peers.get(peer_id, {}).get("phrase", ""))
		if peer_phrase == "" or str(reply.get("proof", "")) != _secret_proof(peer_phrase, nonce + challenge):
			conn.disconnect_from_host()
			return {"ok": false, "error": "secret_mismatch"}
		conn.disconnect_from_host()
		return {"ok": false, "error": "secret_mismatch"}
	# Do not mutate GameManager or save settings on this worker. Callers
	# commit the pairing on the main thread only after the transfer succeeds.
	# Ask the receiver which paths it actually needs before sending payloads.
	var entries := inventory.duplicate() if not inventory.is_empty() else {}
	if entries.is_empty():
		for fname in files:
			var content = files[fname]
			entries[str(fname)] = {"modified": int(times.get(str(fname), 0)), "size": (content as PackedByteArray).size() if typeof(content) == TYPE_PACKED_BYTE_ARRAY else str(content).to_utf8_buffer().size()}
	var client_state := state_fingerprint(entries)
	# Cheap gate: if the peer already applied exactly this content, skip the
	# manifest (and payloads) entirely — an idle sync is a few bytes each way.
	var probe: Variant = _client_roundtrip(conn, {"cmd": "probe", "id": client_id, "state": client_state})
	if typeof(probe) != TYPE_DICTIONARY or not probe.get("ok", false):
		conn.disconnect_from_host()
		return {"ok": false, "error": "probe_failed"}
	if probe.get("already", false):
		conn.disconnect_from_host()
		return {"ok": true, "count": 0, "already": true, "peer_id": peer_id,
			"peer_name": str(reply.get("name", peer_id)), "vault_id": str(reply.get("vault_id", "")),
			"secret": secret, "ip": ip if peer_ip == "" else peer_ip}
	var plan: Variant = _client_roundtrip(conn, {"cmd": "manifest", "entries": entries})
	if typeof(plan) != TYPE_DICTIONARY or not plan.get("ok", false) or typeof(plan.get("needed")) != TYPE_ARRAY:
		conn.disconnect_from_host()
		return {"ok": false, "error": "manifest_failed"}
	var needed: Array = plan["needed"]
	# Stream the cart file-by-file so memory stays bounded (never hold the whole
	# vault's base64 in one frame). The peer pushes one file per frame, and the
	# receiver writes it immediately; only the terminal push_end gets a reply.
	_send_frame(conn, {"cmd": "push_stream", "name": client_name, "id": client_id, "state": client_state, "pending": needed.size()})
	for fname in needed:
		if not entries.has(str(fname)):
			continue
		var content: Variant = files.get(fname, null)
		if content == null and vault != "" and _valid_sync_path(str(fname)):
			var path := vault.path_join(str(fname))
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null:
				continue  # file removed while inventory was being built
			content = f.get_as_text() if str(fname).ends_with(".md") or str(fname).ends_with(".json") else f.get_buffer(f.get_length())
			f.close()
		if content == null:
			continue
		var is_binary: bool = (typeof(content) != TYPE_STRING) or (String(fname) != ".neonnotes-tombstones.json" and not String(fname).ends_with(".md") and not String(fname).ends_with(".json"))
		var text := ""
		if typeof(content) == TYPE_PACKED_BYTE_ARRAY:
			text = Marshalls.raw_to_base64(content)
		else:
			text = String(content)
		var mod := int(entries.get(str(fname), {}).get("modified", times.get(str(fname), 0)))
		var frame := {"cmd": "push_item", "name": String(fname), "text": text, "modified": mod, "binary": is_binary, "size": int(entries.get(str(fname), {}).get("size", -1))}
		# Bounded memory per item; do not block waiting for a reply here.
		_send_frame(conn, frame)
		# Let the receiver interleave its frame processing between items instead
		# of buffering the whole cart.
		OS.delay_msec(10)
	var reply2: Variant = _client_roundtrip(conn, {"cmd": "push_end", "id": peer_id})
	conn.disconnect_from_host()
	if typeof(reply2) != TYPE_DICTIONARY or not reply2.get("ok", false):
		return {"ok": false, "error": str(reply2.get("error", "push_failed")) if typeof(reply2) == TYPE_DICTIONARY else "bad_reply"}
	return {"ok": true, "count": int(reply2.get("count", 0)), "peer_id": peer_id,
		"peer_name": str(reply.get("name", peer_id)), "vault_id": str(reply.get("vault_id", "")),
		"secret": secret, "ip": ip if peer_ip == "" else peer_ip}

## Main-thread only: record a successful peer. `explicit` marks a pairing the
## user drove from the dialog (phrase entered by hand) — only then may the
## joining device adopt the receiver's vault phrase, and only on a *successful*
## handshake. Routine auto-sync never repoints local identity, and the phrase
## itself never travels the wire (see push_to).
static func accept_pair(result: Dictionary, explicit := false) -> void:
	if not result.get("ok", false):
		return
	var peer_id := str(result.get("peer_id", ""))
	var vault_id := str(result.get("vault_id", ""))
	var secret := str(result.get("secret", ""))
	if peer_id == "" or vault_id == "" or secret == "":
		return
	if peer_id == GameManager.device_id:
		return  # a device is never its own peer
	# A known peer with a different phrase may only repoint us when the user
	# explicitly re-paired; otherwise leave local identity alone.
	if GameManager.trusted.has(peer_id) and secret != GameManager.vault_secret and not explicit:
		return
	if not GameManager.trusted.has(peer_id) or explicit:
		GameManager.vault_secret = secret
		GameManager.vault_id = vault_id
	GameManager.paired_vault_id = vault_id
	GameManager.paired_peers[peer_id] = {"name": str(result.get("peer_name", peer_id)), "vault_id": vault_id, "ip": str(result.get("ip", "")), "phrase": secret}
	GameManager.add_trusted(peer_id)
	GameManager._save_settings()

static func _client_roundtrip(conn: StreamPeerTCP, msg: Dictionary, wait_ms := 15000) -> Variant:
	var bytes := JSON.stringify(msg).to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, bytes.size())
	frame.append_array(bytes)
	conn.put_data(frame)
	var start := Time.get_ticks_msec()
	var buf := PackedByteArray()
	while Time.get_ticks_msec() - start < wait_ms:
		conn.poll()
		var status := conn.get_status()
		# Only read while the socket is open; get_available_bytes() on a closed
		# StreamPeerTCP logs an engine error and returns -1.
		if status == StreamPeerTCP.STATUS_CONNECTED and conn.get_available_bytes() > 0:
			buf = buf + conn.get_data(conn.get_available_bytes())[1]
		if buf.size() >= 4:
			var length := buf.decode_u32(0)
			if buf.size() >= 4 + length:
				return JSON.parse_string(buf.slice(4, 4 + length).get_string_from_utf8())
		if status != StreamPeerTCP.STATUS_CONNECTED:
			return null
		OS.delay_msec(1)  # yield while waiting so the worker never busy-spins
	return null

# ---------------- Notes ----------------

func _sync_log(message: String) -> void:
	# Visible in the Godot output window (debug builds / NEONNOTES_SYNC_DEBUG=1).
	# Also appended to user://sync.log for post-mortem inspection on device.
	if debug_log:
		print("[sync %s] %s" % [Time.get_time_string_from_system(), message])
	var path := "user://sync.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("[%s] %s" % [Time.get_datetime_string_from_system(), message])
	var too_big := f.get_length() > 1024 * 1024  # stat, not a full re-read
	f.close()
	if too_big:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## Markdown's hidden updated field survives a device restart and a received
## file's local disk timestamp. Legacy notes/media fall back to disk mtimes.
## Logical mtime for a path: the persisted record (received files, local saves)
## when we have one, else the disk mtime. Deliberately reads no file contents —
## this runs per entry in the receiver's manifest handler, on the main thread,
## and previously opened every note's front-matter (hundreds of file reads per
## sync). Durability now comes from the persisted `_mtimes`, not front-matter.
static func _file_logical_time(path: String, name: String, mtimes: Dictionary = {}) -> int:
	if mtimes.has(name):
		return int(mtimes[name])
	return FileAccess.get_modified_time(path)

## Inventory paths and sizes off the UI thread, without reading any payloads.
## The receiver requests only missing/newer files. Tombstones are always offered.
func collect_manifest(ts: Dictionary, vault: String, note_list: Array, mtimes: Dictionary = {}) -> Dictionary:
	var entries := {}
	var paths: Array[String] = []
	for fname in note_list:
		paths.append(str(fname))
	if FileAccess.file_exists(vault.path_join(".neonnotes.json")):
		paths.append(".neonnotes.json")
	_collect_media(vault.path_join("media"), vault, paths)
	for name in paths:
		var path := vault.path_join(name)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var size := f.get_length()
		f.close()
		if size == 0 and not name.ends_with(".md") and not name.ends_with(".json"):
			continue
		entries[name] = {"modified": _file_logical_time(path, name, mtimes), "size": size}
	if not ts.is_empty():
		# Deterministic tombstone contribution. A "now" timestamp here made the
		# fingerprint change on every sync whenever any tombstone existed, so
		# `_confirmed` could never match and every peer re-exchanged a full
		# manifest — and the receiver opened every file answering it (a multi
		# second main-thread stall on mobile). Hash the content instead: stable
		# while the tombstones are unchanged, different when they change.
		var tomb_text := JSON.stringify(ts)
		entries[".neonnotes-tombstones.json"] = {"modified": 0, "size": tomb_text.hash()}
	return entries

func _collect_media(dir_path: String, vault: String, paths: Array[String]) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	for name in DirAccess.get_files_at(dir_path):
		var rel := dir_path.path_join(name).trim_prefix(vault + "/")
		paths.append(rel)
	for name in DirAccess.get_directories_at(dir_path):
		_collect_media(dir_path.path_join(name), vault, paths)

## device name shared over the wire (env override or generated)
static func device_display_name() -> String:
	var env := OS.get_environment("NEONNOTES_DEVICE")
	return env if env != "" else "%s-%d" % [OS.get_name(), abs(int(GameManager.device_id.hash()) % 100)]

# ---------------- Auto-sync ----------------
## Push local notes to every visible trusted peer. Called debounced after
## edits and periodically while discovery runs. LWW on the receiver keeps
## the newest copy.

var _auto_timer: Timer
var _retry_timer: Timer
var _syncing := false
var _tcp_error_reported := false
var _peer_sync_times: Dictionary = {}
var _tombstones: Dictionary = {}
## Logical modification times for files received this session (rel path -> unix
## seconds). Writing a received file would otherwise stamp it with the *local*
## clock, so every re-sent copy would look newer than any older tombstone and a
## deleted file could be resurrected ("bounce"). We keep the sender's timestamp
## and re-send that instead; a genuine local write drops the entry (see
## note_saved/note_restored) so true local edits still win.
var _mtimes: Dictionary = {}
## Persistent per-vault sync state (user://sync_state.json, keyed by vault path):
## the logical mtimes and tombstones above survive restarts, and `_confirmed`
## records the content fingerprint we last fully applied from each peer.
var _state_key := ""
var _confirmed: Dictionary = {}   # peer device_id -> fingerprint we have applied
var _state_timer: Timer
var persist_state := true         # tests set false for hermetic runs
var state_file_override := ""     # harnesses point this at a throwaway file

var _sync_thread: Thread
var _sync_result: Array = []
var _sync_mutex := Mutex.new()
var _shutting_down := false

## Mirror `_sync_log` messages to the Godot output window (the editor's Output
## panel, or `adb logcat` for a debug APK). Defaults to debug builds; override
## with NEONNOTES_SYNC_DEBUG=1 (force on) or =0 (force off).
var debug_log := _debug_log_default()
static func _debug_log_default() -> bool:
	var env := OS.get_environment("NEONNOTES_SYNC_DEBUG")
	if env == "1":
		return true
	if env == "0":
		return false
	return OS.is_debug_build()
## Last `_process` tick, for the main-thread stall detector below.
var _last_frame_ms := 0

## Stable fingerprint of a vault's manifest (paths + logical mtimes + sizes).
## Deterministic, so a peer reverting to a previously-sent content set compares
## equal and is correctly skipped. Only ever compared against the peer that
## declared it, so per-device clock/disk differences do not matter.
static func state_fingerprint(entries: Dictionary) -> String:
	var keys := entries.keys()
	keys.sort()
	var buf := ""
	for k in keys:
		var e: Dictionary = entries[k] if typeof(entries[k]) == TYPE_DICTIONARY else {}
		buf += "%s|%d|%d\n" % [str(k), int(e.get("modified", 0)), int(e.get("size", -1))]
	return buf.sha256_text()

func _vault_key() -> String:
	return GameManager.vault_abs().md5_text()

func _ensure_state_loaded() -> void:
	var key := _vault_key()
	if key == _state_key:
		return
	_state_key = key
	_mtimes.clear()
	_tombstones.clear()
	_confirmed.clear()
	if not _persistence_enabled():
		return
	var f := FileAccess.open(_state_file(), FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var rec = parsed.get(key, {})
	if typeof(rec) != TYPE_DICTIONARY:
		return
	if rec.has("mtimes") and typeof(rec["mtimes"]) == TYPE_DICTIONARY:
		_mtimes = rec["mtimes"]
	if rec.has("tombstones") and typeof(rec["tombstones"]) == TYPE_DICTIONARY:
		_tombstones = rec["tombstones"]
	if rec.has("confirmed") and typeof(rec["confirmed"]) == TYPE_DICTIONARY:
		_confirmed = rec["confirmed"]
	_sync_log("STATE loaded vault=%s mtimes=%d tombstones=%d confirmed=%d" % [key, _mtimes.size(), _tombstones.size(), _confirmed.size()])

func _state_file() -> String:
	return state_file_override if state_file_override != "" else "user://sync_state.json"

## Persist only in a real app session. Test harnesses set
## GameManager.suppress_settings_save (they must never touch real state), but an
## explicit state_file_override is a deliberate throwaway-file choice.
func _persistence_enabled() -> bool:
	if not persist_state:
		return false
	if state_file_override != "":
		return true
	return not GameManager.suppress_settings_save

func _save_state() -> void:
	if not _persistence_enabled():
		return
	if _state_key != _vault_key():
		return  # not loaded for this vault yet — do not clobber stored state
	var data := {}
	var f := FileAccess.open(_state_file(), FileAccess.READ)
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			data = parsed
	data[_vault_key()] = {"mtimes": _mtimes, "tombstones": _tombstones, "confirmed": _confirmed}
	var out := FileAccess.open(_state_file(), FileAccess.WRITE)
	if out:
		out.store_string(JSON.stringify(data))
		out.close()

## Persist soon, but coalesce bursts. With no timer (tests) save immediately.
func _mark_state_dirty() -> void:
	if not _persistence_enabled():
		return
	if _state_timer == null:
		_save_state()
		return
	_state_timer.stop()
	_state_timer.start()

func _exit_tree() -> void:
	_shutting_down = true
	_save_state()
	set_process(false)
	if _auto_timer:
		_auto_timer.stop()
	if _retry_timer:
		_retry_timer.stop()
	stop_discovery()
	if _sync_thread != null:
		# The worker uses bounded socket timeouts; join before the node is
		# released so no worker can access this service after teardown.
		_sync_thread.wait_to_finish()
		_sync_thread = null

func enable_auto_sync() -> void:
	if _shutting_down or GameManager.suppress_settings_save:
		return  # ephemeral test/dev session — never push to real peers
	if _auto_timer:
		return
	_auto_timer = Timer.new()
	_auto_timer.one_shot = true  # debounce after edits; the 20 s retry timer is the periodic sweep
	_auto_timer.wait_time = 2.5
	_auto_timer.timeout.connect(auto_sync)
	add_child(_auto_timer)
	_auto_timer.start()
	_retry_timer = Timer.new()
	_retry_timer.name = "SyncRetryTimer"
	_retry_timer.wait_time = 20.0
	_retry_timer.timeout.connect(auto_sync)
	add_child(_retry_timer)
	_retry_timer.start()
	_state_timer = Timer.new()
	_state_timer.name = "SyncStateTimer"
	_state_timer.one_shot = true
	_state_timer.wait_time = 3.0
	_state_timer.timeout.connect(_save_state)
	add_child(_state_timer)
	_ensure_state_loaded()

func note_deleted(path: String) -> void:
	_ensure_state_loaded()
	_tombstones[path] = Time.get_unix_time_from_system()
	_mtimes.erase(path)
	note_saved()

## A path was (re)created or written locally. Forget any tombstone for it and
## assert the file is alive "now": moves preserve the source file's old mtime,
## so without this a folder moved back onto a previously deleted path would
## stay blocked on peers. Peers accept it because this timestamp beats their
## tombstone.
func note_restored(path: String) -> void:
	if path == "":
		return
	_ensure_state_loaded()
	_tombstones.erase(path)
	_mtimes[path] = Time.get_unix_time_from_system()

func note_saved(path := "") -> void:
	_change_generation += 1
	if path != "":
		note_restored(path)
	_ensure_state_loaded()
	_mark_state_dirty()
	_pending_unsynced = true
	sync_pending.emit()
	if _auto_timer == null:
		return
	_auto_timer.stop()
	_auto_timer.start()  # short debounce: sync shortly after each edit

func auto_sync() -> void:
	if _shutting_down or _syncing or GameManager.trusted.is_empty():
		return
	_ensure_state_loaded()
	# One single-flight transfer; periodic timer also discovers peers when edits are idle.
	# When broadcast discovery failed (UDP bind error / null _udp), fall through so a
	# stored trusted peer IP can still be used over TCP.
	if not _pending_unsynced and _udp != null and peers.is_empty():
		return
	_syncing = true
	var targets: Array = []
	for ip in peers.keys():
		var p: Dictionary = peers[ip]
		var pid := str(p.get("id", ""))
		if pid != "" and pid != GameManager.device_id and GameManager.trusted.has(pid):
			targets.append({"ip": str(ip), "port": int(p.get("tcp", TCP_PORT)), "name": str(p.get("name", ip)), "id": pid})
	if targets.is_empty():
		# Broadcast discovery can fail asymmetrically (e.g. phone's UDP listener
		# not reached). Fall back to the last known IP of trusted paired peers.
		for pid in GameManager.trusted:
			if not GameManager.paired_peers.has(pid):
				continue
			var rec: Dictionary = GameManager.paired_peers[pid]
			if pid != GameManager.device_id and str(rec.get("ip", "")).is_valid_ip_address():
				targets.append({"ip": str(rec["ip"]), "port": TCP_PORT, "name": str(rec.get("name", pid)), "id": pid})
	if targets.is_empty():
		_syncing = false
		return
	# Snapshot tombstones and logical mtimes on the main thread (small) and let
	# the worker read the actual file payloads off the UI thread.
	_sync_mutex.lock()
	var ts: Dictionary = _tombstones.duplicate()
	var mtimes: Dictionary = _mtimes.duplicate()
	_sync_mutex.unlock()
	var vault: String = GameManager.vault_abs()
	var note_list: Array = GameManager.notes.duplicate()
	_sync_thread = Thread.new()
	_sync_thread.start(_sync_worker.bind(targets, ts, vault, note_list, mtimes, _change_generation, GameManager.vault_secret, GameManager.device_id, device_name))
	return

func _sync_worker(targets: Array, ts: Dictionary, vault: String, note_list: Array, mtimes: Dictionary, generation: int, secret: String, client_id: String, client_name: String) -> void:
	var successful := 0
	var pairs: Array[Dictionary] = []
	var completed := false
	var last_name := "peer"
	var failure := ""
	var failures := 0
	var manifest_start := Time.get_ticks_msec()
	var entries: Dictionary = collect_manifest(ts, vault, note_list, mtimes)
	_sync_log("OUT manifest entries=%d tombstones=%d took=%d ms" % [entries.size(), ts.size(), Time.get_ticks_msec() - manifest_start])
	var files := {}
	if not ts.is_empty():
		files[".neonnotes-tombstones.json"] = JSON.stringify(ts)
	if entries.is_empty():
		_sync_mutex.lock()
		_sync_result.append({"ok": true, "count": 0, "name": "peer", "error": "", "generation": generation})
		_sync_mutex.unlock()
		return
	for target in targets:
		last_name = str(target["name"])
		_sync_log("OUT start peer=%s files=%d" % [last_name, entries.size()])
		var phrase := secret
		if str(target.get("id", "")) != "" and not GameManager.trusted.is_empty():
			var rec: Dictionary = GameManager.paired_peers.get(str(target["id"]), {})
			if str(rec.get("phrase", "")) != "":
				phrase = str(rec["phrase"])
		var push_start := Time.get_ticks_msec()
		var result: Dictionary = push_to(str(target["ip"]), int(target["port"]), phrase, files, 4000, {}, str(target["ip"]), entries, vault, client_id, client_name)
		if result.get("ok", false):
			pairs.append(result)
			completed = true
			successful += int(result.get("count", 0))
			if result.get("already", false):
				_sync_log("OUT done peer=%s already-in-sync (probe skipped) took=%d ms" % [last_name, Time.get_ticks_msec() - push_start])
			else:
				_sync_log("OUT done peer=%s acknowledged=%d took=%d ms" % [last_name, int(result.get("count", 0)), Time.get_ticks_msec() - push_start])
		else:
			failures += 1
			failure = "%s: %s" % [last_name, str(result.get("error", "unavailable"))]
			_sync_log("OUT failed peer=%s error=%s took=%d ms" % [last_name, failure, Time.get_ticks_msec() - push_start])
	_sync_mutex.lock()
	# A transfer that completed but wrote zero files (peer already up to date) is
	# still a successful sync, not a failure — otherwise the status dot stays red.
	_sync_result.append({"ok": completed, "count": successful, "name": last_name, "error": failure, "generation": generation, "pairs": pairs, "failures": failures})
	_sync_mutex.unlock()
