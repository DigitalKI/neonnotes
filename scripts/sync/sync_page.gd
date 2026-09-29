class_name SyncPage
extends MarginContainer
## LAN sync as a full in-app page (same pattern as the settings page), not a
## dialog: on mobile it owns the whole visible screen. The host shows/hides it
## and connects close_requested. The page never frees itself — main owns
## `service` for background auto-sync, so hiding the page must not stop it.

signal close_requested

var service: SyncService  # injected instance (main owns it for auto-sync)
var _service: SyncService
var _send_thread: Thread
var _send_result: Dictionary = {}
var _send_running := false
var _send_peer := ""

@onready var _device_label: Label = %DeviceLabel
@onready var _pin_label: Label = %PinLabel
@onready var _discovery_btn: Button = %DiscoveryToggle
@onready var _peer_list: ItemList = %PeerList
@onready var _pin_edit: LineEdit = %PinEdit
@onready var _send_btn: Button = %SendBtn
@onready var _log: RichTextLabel = %SyncLog
@onready var _status_label: Label = %StatusLabel
@onready var _close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	_discovery_btn.toggled.connect(_on_discovery_toggled)
	_send_btn.pressed.connect(_on_send)
	_close_btn.pressed.connect(func(): close_requested.emit())
	# A scene instance is already in the tree, so main cannot inject `service`
	# before _ready: bind_service() rebinds to the host's instance later. A
	# standalone instantiation (tests) falls back to owning its own service.
	_service = service if service != null else SyncService.new()
	if service == null:
		_service.name = "SyncService"
		add_child(_service)
	_attach_service()

## Adopt the host's SyncService (needed because the page is a persistent scene
## instance whose _ready runs before main's). Safe to call more than once.
func bind_service(s: SyncService) -> void:
	if s == null or s == _service:
		return
	if _service != null and _service != service and is_instance_valid(_service) and _service.get_parent() == self:
		_service.queue_free()
	_service = s
	_attach_service()

func _attach_service() -> void:
	if _service.peers_changed.is_connected(_refresh_peers):
		return
	_service.peers_changed.connect(_refresh_peers)
	_service.sync_done.connect(_on_sync_done)
	_service.sync_failed.connect(_on_sync_failed)

## Called by the host every time the page is shown.
func open() -> void:
	var pal: Dictionary = GameManager.palette()
	_pin_label.text = "Pairing words: " + GameManager.vault_secret
	_pin_edit.text = ""
	var paired_text := "Not paired"
	if not GameManager.paired_peers.is_empty():
		var names: Array[String] = []
		for peer in GameManager.paired_peers.values():
			names.append(str(peer.get("name", "paired device")))
		paired_text = "Paired with: " + ", ".join(names)
	_device_label.text = "Device: " + _service.device_name + "\nID: " + GameManager.device_id + "\nVault: " + GameManager.vault_id + "\n" + paired_text
	_log.append_text("[color=%s]Share your pairing words with the other device once. Select its vault, enter its words there, and pair. Trusted devices reconnect automatically.[/color]\n" % _css(pal.get("accent2", Color.GRAY)))
	visible = true

func _css(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]

func _on_discovery_toggled(pressed: bool) -> void:
	if pressed:
		if _service.start_discovery():
			_service.enable_auto_sync()
			_discovery_btn.text = "Stop Discovery"
			_log.append_text("Discovery started. Looking for vaults on this LAN…\n")
			_status_label.text = "Searching for nearby devices…"
		else:
			_discovery_btn.button_pressed = false
			_log.append_text("[color=red]Could not bind UDP port %d. Is another instance running?[/color]\n" % SyncService.DISCOVERY_PORT)
	else:
		_service.stop_discovery()
		_discovery_btn.text = "Start Discovery"
		_peer_list.clear()
		_log.append_text("Discovery stopped.\n")

func _refresh_peers() -> void:
	var selected_ip := ""
	_status_label.text = "Found %d device(s)." % _service.peers.size()
	var idx := _peer_list.get_selected_items()
	if idx.size() > 0:
		selected_ip = _peer_list.get_item_metadata(idx[0])
	_peer_list.clear()
	var i := 0
	for ip in _service.peers.keys():
		var p: Dictionary = _service.peers[ip]
		_peer_list.add_item("◆ Vault %s\n%s" % [str(p.get("vault_id", "unknown")), str(p["name"])])
		_peer_list.set_item_metadata(i, ip)
		if ip == selected_ip:
			_peer_list.select(i)
		i += 1

func _on_send() -> void:
	if _send_running:
		return
	var sel := _peer_list.get_selected_items()
	if sel.is_empty():
		_status_label.text = "Select a vault first."
		return
	var ip := str(_peer_list.get_item_metadata(sel[0]))
	var p: Dictionary = _service.peers.get(ip, {})
	var secret := _pin_edit.text.strip_edges().to_lower().replace(" ", "-")
	if GameManager.trusted.has(str(p.get("id", ""))) and secret == "":
		secret = GameManager.vault_secret
	if secret == "":
		_status_label.text = "Enter the remote vault's pairing words."
		return
	_send_peer = str(p.get("name", ip))
	_status_label.text = "Syncing with %s…" % _send_peer
	_send_btn.disabled = true
	_send_running = true
	_send_result = {}
	# Snapshot small state on UI thread; collect payloads and transfer on worker.
	var ts := _service._tombstones.duplicate()
	var mtimes := _service._mtimes.duplicate()
	var vault := GameManager.vault_abs()
	var paths := GameManager.notes.duplicate()
	var client_id := GameManager.device_id
	var client_name := _service.device_name
	_send_thread = Thread.new()
	_send_thread.start(func():
		var entries := _service.collect_manifest(ts, vault, paths, mtimes)
		var files := {}
		if not ts.is_empty():
			files[".neonnotes-tombstones.json"] = JSON.stringify(ts)
		_send_result = SyncService.push_to(ip, int(p.get("tcp", SyncService.TCP_PORT)), secret, files, 4000, {}, ip, entries, vault, client_id, client_name))

func _process(_delta: float) -> void:
	if _send_thread == null or _send_thread.is_alive():
		return
	_send_thread.wait_to_finish()
	_send_thread = null
	_send_running = false
	_send_btn.disabled = false
	if _send_result.get("ok", false):
		SyncService.accept_pair(_send_result, true)  # user drove this pairing
		_pin_label.text = "Pairing words: " + GameManager.vault_secret
		_device_label.text = "Device: %s\nID: %s\nVault: %s" % [_service.device_name, GameManager.device_id, GameManager.vault_id]
		_pin_edit.clear()
		var count := int(_send_result.get("count", 0))
		_status_label.text = "Synced %d files with %s." % [count, _send_peer]
		_log.append_text("[color=green]%s[/color]\n" % _status_label.text)
	else:
		_status_label.text = "Sync failed: %s" % str(_send_result.get("error", "?"))
		_log.append_text("[color=red]%s[/color]\n" % _status_label.text)

func _exit_tree() -> void:
	if _send_thread != null:
		# Only app teardown reaches this with an active worker. The TCP waits
		# have timeouts; hiding the page defers nothing and never blocks the UI.
		_send_thread.wait_to_finish()
		_send_thread = null

func _on_sync_done(peer_name: String, count: int) -> void:
	_log.append_text("[color=green]Received %d notes from %s[/color]\n" % [count, peer_name])

func _on_sync_failed(reason: String) -> void:
	_log.append_text("[color=red]Sync failed: %s[/color]\n" % reason)
