class_name SyncService
extends Node

signal peers_changed
signal sync_done(peer_name: String, count: int)
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
var expected_pin := ""
var _pending_unsynced := false

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
		var now := Time.get_ticks_msec()
		if not peers.has(ip):
			peers[ip] = {"name": str(data.get("name", "peer")), "id": str(data.get("id", "")), "vault_id": str(data.get("vault_id", "")), "tcp": int(data.get("tcp", TCP_PORT)), "seen": now}
			peers_changed.emit()
		else:
			peers[ip]["seen"] = now
			peers[ip]["name"] = str(data.get("name", peers[ip]["name"]))
			peers[ip]["id"] = str(data.get("id", peers[ip].get("id", "")))
			peers[ip]["vault_id"] = str(data.get("vault_id", peers[ip].get("vault_id", "")))

# ---------------- Pin / codes ----------------

func set_pin(pin: String) -> void:
	expected_pin = pin
	if pin != "" and GameManager.sync_pin == "":
		GameManager.sync_pin = pin
		GameManager._save_settings()

func gen_pin() -> String:
	return "%06d" % (randi() % 1000000)

func gen_words() -> String:
	var out := []
	for i in 3:
		out.append(WORDS[randi() % WORDS.size()])
	return "-".join(out)

# ---------------- Server ----------------

func _ensure_server() -> bool:
	if _server and _server.is_listening():
		return true
	if not _broadcasting:
		return false  # sync not active — don't bind ports in the background
	_server = TCPServer.new()
	# "*" is Godot's portable all-interface bind address. Some mobile
	# platforms reject the literal 0.0.0.0 here even though desktop accepts it.
	var err := _server.listen(TCP_PORT, "*")
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
	while _server.is_connection_available():
		var conn: StreamPeerTCP = _server.take_connection()
		_partial[conn.get_instance_id()] = {"conn": conn, "buf": PackedByteArray(), "paired": false}
	var done_ids := []
	for id in _partial.keys():
		var st: Dictionary = _partial[id]
		var conn: StreamPeerTCP = st["conn"]
		conn.poll()
		var status := conn.get_status()
		if status == StreamPeerTCP.STATUS_ERROR:
			conn.disconnect_from_host()
			done_ids.append(id)
			continue
		if conn.get_available_bytes() > 0:
			st["buf"] = st["buf"] + conn.get_data(conn.get_available_bytes())[1]
		# Try to parse framed messages
		var buf: PackedByteArray = st["buf"]
		while buf.size() >= 4:
			var length := buf.decode_u32(0)
			if length > 32 * 1024 * 1024:
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
			var reply := _handle_message(conn, msg, st)
			_send_json(conn, reply)
			if not st.get("paired", false):
				# unauthenticated: drop connection after reply
				conn.disconnect_from_host()
				done_ids.append(id)
				break
			if String(msg.get("cmd", "")) == "push":
				conn.disconnect_from_host()
				done_ids.append(id)
				break
		if done_ids.has(id):
			continue
	for id in done_ids:
		_partial.erase(id)

func _handle_message(_conn: StreamPeerTCP, msg: Dictionary, st: Dictionary) -> Dictionary:
	var cmd := String(msg.get("cmd", ""))
	if cmd == "pair":
		var sender_id := String(msg.get("id", ""))
		var trusted_ok: bool = sender_id != "" and GameManager.trusted.has(sender_id)
		if not trusted_ok and (expected_pin == "" or String(msg.get("pin", "")) != expected_pin):
			return {"ok": false, "error": "auth"}
		st["paired"] = true
		st["peer_id"] = sender_id
		return {"ok": true, "name": device_name, "id": GameManager.device_id, "vault_id": GameManager.vault_id, "pin": expected_pin}
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
		var vault := GameManager.vault_abs()
		if vault == "":
			return {"ok": false, "error": "no_vault"}
		for fname in files.keys():
			var name := String(fname)
			# allow subfolders; reject traversal/absolute paths and exports
			if name == "" or name.begins_with("/") or name.contains("\\") or name.contains("..") \
					or name.get_base_dir() == GameManager.EXPORTS_SUBDIR:
				continue
			var dest := vault.path_join(name)
			var text := String(files[fname])
			var binary := not name.ends_with(".md") and not name.ends_with(".json")
			# last-writer-wins: skip if our local copy is strictly newer
			if FileAccess.file_exists(dest) and times.has(fname):
				var local_t := FileAccess.get_modified_time(dest)
				var remote_t := int(times[fname])
				if local_t > remote_t:
					continue
			DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
			var f := FileAccess.open(dest, FileAccess.WRITE)
			if f == null:
				continue
			if binary:
				f.store_buffer(Marshalls.base64_to_raw(text))
			else:
				f.store_string(text)
			f.close()
			count += 1
		if count > 0:
			GameManager.scan_notes()
		var peer_id := String(msg.get("id", ""))
		if peer_id != "":
			GameManager.add_trusted(peer_id)  # successfully paired+pushed → remember
		sync_done.emit(str(msg.get("name", "peer")), count)
		return {"ok": true, "count": count}
	return {"ok": false, "error": "unknown_cmd"}

func _send_json(conn: StreamPeerTCP, data: Dictionary) -> void:
	var bytes := JSON.stringify(data).to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, bytes.size())
	frame.append_array(bytes)
	conn.put_data(frame)

# ---------------- Client ----------------

static func push_to(ip: String, port: int, pin: String, files: Dictionary, timeout_ms := 4000, times: Dictionary = {}) -> Dictionary:
	var conn := StreamPeerTCP.new()
	var err := conn.connect_to_host(ip, port)
	if err != OK:
		return {"ok": false, "error": "connect_failed"}
	var start := Time.get_ticks_msec()
	while conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		conn.poll()
		if conn.get_status() == StreamPeerTCP.STATUS_ERROR or Time.get_ticks_msec() - start > timeout_ms:
			return {"ok": false, "error": "timeout"}
	var reply: Variant = _client_roundtrip(conn, {"cmd": "pair", "pin": pin, "id": GameManager.device_id})
	if typeof(reply) != TYPE_DICTIONARY or not reply.get("ok", false):
		conn.disconnect_from_host()
		return {"ok": false, "error": str(reply.get("error", "auth")) if typeof(reply) == TYPE_DICTIONARY else "bad_reply"}
	# remember the peer as trusted once pairing succeeded
	var peer_id := String(reply.get("id", ""))
	if peer_id != "":
		GameManager.add_trusted(peer_id)
		GameManager.paired_vault_id = String(reply.get("vault_id", ""))
		GameManager.paired_peers[peer_id] = {"name": str(reply.get("name", peer_id)), "vault_id": GameManager.paired_vault_id, "pin": str(reply.get("pin", ""))}
		GameManager._save_settings()
	var reply2: Variant = _client_roundtrip(conn, {"cmd": "push", "files": files, "times": times, "name": device_display_name(), "id": GameManager.device_id})
	conn.disconnect_from_host()
	if typeof(reply2) != TYPE_DICTIONARY or not reply2.get("ok", false):
		return {"ok": false, "error": str(reply2.get("error", "push_failed")) if typeof(reply2) == TYPE_DICTIONARY else "bad_reply"}
	return {"ok": true, "count": int(reply2.get("count", 0))}

static func _client_roundtrip(conn: StreamPeerTCP, msg: Dictionary) -> Variant:
	var bytes := JSON.stringify(msg).to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, bytes.size())
	frame.append_array(bytes)
	conn.put_data(frame)
	var start := Time.get_ticks_msec()
	var buf := PackedByteArray()
	while Time.get_ticks_msec() - start < 4000:
		conn.poll()
		if conn.get_status() == StreamPeerTCP.STATUS_ERROR:
			return null
		if conn.get_available_bytes() > 0:
			buf = buf + conn.get_data(conn.get_available_bytes())[1]
		if buf.size() >= 4:
			var length := buf.decode_u32(0)
			if buf.size() >= 4 + length:
				return JSON.parse_string(buf.slice(4, 4 + length).get_string_from_utf8())
	return null

# ---------------- Notes ----------------

func collect_notes() -> Dictionary:
	var files := {}
	var times := {}
	var vault := GameManager.vault_abs()
	# Transfer markdown and embedded media, but never generated exports.
	var paths: Array[String] = []
	for fname in GameManager.notes:
		paths.append(String(fname))
	_collect_media(vault.path_join("media"), vault, paths)
	for name in paths:
		var path := vault.path_join(name)
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			files[name] = f.get_as_text() if name.ends_with(".md") or name.ends_with(".json") else Marshalls.raw_to_base64(f.get_buffer(f.get_length()))
			times[name] = FileAccess.get_modified_time(path)
			f.close()
	return {"files": files, "times": times}

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
var _sync_thread: Thread
var _sync_result: Array = []
var _sync_mutex := Mutex.new()

func enable_auto_sync() -> void:
	if _auto_timer:
		return
	_auto_timer = Timer.new()
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

func note_saved() -> void:
	_pending_unsynced = true
	sync_pending.emit()
	if _auto_timer == null:
		return
	_auto_timer.stop()
	_auto_timer.start()  # short debounce: sync shortly after each edit

func auto_sync() -> void:
	if _syncing or _udp == null or GameManager.trusted.is_empty():
		return
	# One single-flight transfer; periodic timer also discovers peers when edits are idle.
	if not _pending_unsynced and peers.is_empty():
		return
	_syncing = true
	var data: Dictionary = collect_notes()
	if data["files"].is_empty():
		_syncing = false
		return
	var targets: Array = []
	for ip in peers.keys():
		var p: Dictionary = peers[ip]
		var pid := str(p.get("id", ""))
		if pid != "" and GameManager.trusted.has(pid):
			targets.append({"ip": str(ip), "port": int(p.get("tcp", TCP_PORT)), "name": str(p.get("name", ip))})
	if targets.is_empty():
		_syncing = false
		return
	_sync_thread = Thread.new()
	_sync_thread.start(_sync_worker.bind(targets, data["files"], data["times"]))
	return

func _sync_worker(targets: Array, files: Dictionary, times: Dictionary) -> void:
	var successful := 0
	var last_name := "peer"
	var failure := ""
	for target in targets:
		last_name = str(target["name"])
		var result: Dictionary = push_to(str(target["ip"]), int(target["port"]), "", files, 4000, times)
		if result.get("ok", false):
			successful += int(result.get("count", 0))
		else:
			failure = "%s: %s" % [last_name, str(result.get("error", "unavailable"))]
	_sync_mutex.lock()
	_sync_result.append({"ok": successful > 0, "count": successful, "name": last_name, "error": failure})
	_sync_mutex.unlock()
