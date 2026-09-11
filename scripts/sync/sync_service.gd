class_name SyncService
extends Node

signal peers_changed
signal sync_done(peer_name: String, count: int)
signal sync_failed(reason: String)

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
		device_name = "%s-%d" % [OS.get_name(), randi() % 100]

# ---------------- Discovery ----------------

func start_discovery() -> bool:
	stop_discovery()
	_udp = PacketPeerUDP.new()
	if not _udp.bind(DISCOVERY_PORT):
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
	var msg := JSON.stringify({"proto": MAGIC, "name": device_name, "tcp": TCP_PORT})
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
	_poll_discovery()
	_poll_server()

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
			peers[ip] = {"name": str(data.get("name", "peer")), "tcp": int(data.get("tcp", TCP_PORT)), "seen": now}
			peers_changed.emit()
		else:
			peers[ip]["seen"] = now
			peers[ip]["name"] = str(data.get("name", peers[ip]["name"]))

# ---------------- Pin / codes ----------------

func set_pin(pin: String) -> void:
	expected_pin = pin

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
	_server = TCPServer.new()
	# "*" is Godot's portable all-interface bind address. Some mobile
	# platforms reject the literal 0.0.0.0 here even though desktop accepts it.
	var err := _server.listen(TCP_PORT, "*")
	if err != OK:
		_server = null
		sync_failed.emit("Could not open TCP port %d (error %s). Check firewall or another NeonNotes instance." % [TCP_PORT, error_string(err)])
		return false
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
		if expected_pin == "" or String(msg.get("pin", "")) != expected_pin:
			return {"ok": false, "error": "auth"}
		st["paired"] = true
		return {"ok": true, "name": device_name}
	if cmd == "push":
		if not st.get("paired", false):
			return {"ok": false, "error": "auth"}
		var files = msg.get("files", {})
		if typeof(files) != TYPE_DICTIONARY:
			return {"ok": false, "error": "bad_files"}
		var count := 0
		var vault := GameManager.vault_abs()
		if vault == "":
			return {"ok": false, "error": "no_vault"}
		for fname in files.keys():
			var name := String(fname)
			if name == "" or name.contains("/") or name.contains("\\") or name.contains(".."):
				continue
			var text := String(files[fname])
			var f := FileAccess.open(vault.path_join(name), FileAccess.WRITE)
			if f == null:
				continue
			f.store_string(text)
			f.close()
			count += 1
		if count > 0:
			GameManager.scan_notes()
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

static func push_to(ip: String, port: int, pin: String, files: Dictionary, timeout_ms := 4000) -> Dictionary:
	var conn := StreamPeerTCP.new()
	var err := conn.connect_to_host(ip, port)
	if err != OK:
		return {"ok": false, "error": "connect_failed"}
	var start := Time.get_ticks_msec()
	while conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		conn.poll()
		if conn.get_status() == StreamPeerTCP.STATUS_ERROR or Time.get_ticks_msec() - start > timeout_ms:
			return {"ok": false, "error": "timeout"}
	var reply: Variant = _client_roundtrip(conn, {"cmd": "pair", "pin": pin})
	if typeof(reply) != TYPE_DICTIONARY or not reply.get("ok", false):
		conn.disconnect_from_host()
		return {"ok": false, "error": str(reply.get("error", "auth")) if typeof(reply) == TYPE_DICTIONARY else "bad_reply"}
	var reply2: Variant = _client_roundtrip(conn, {"cmd": "push", "files": files, "name": OS.get_environment("NEONNOTES_DEVICE")})
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
	var out := {}
	var vault := GameManager.vault_abs()
	for fname in GameManager.notes:
		var path := vault.path_join(String(fname))
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			out[String(fname)] = f.get_as_text()
			f.close()
	return out
