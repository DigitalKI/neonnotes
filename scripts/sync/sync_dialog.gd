class_name SyncDialog
extends AcceptDialog

var service: SyncService  # optional injected instance (main owns it for auto-sync)
var _service: SyncService
var _device_label: Label
var _pin_label: Label
var _discovery_btn: Button
var _peer_list: ItemList
var _pin_edit: LineEdit
var _log: RichTextLabel
var _send_btn: Button
var _status_label: Label

func _ready() -> void:
	_device_label = get_node("Root/DeviceRow/DeviceLabel")
	_pin_label = get_node("Root/DeviceRow/PinLabel")
	_discovery_btn = get_node("Root/Columns/DiscoveryToggle")
	_peer_list = get_node("Root/Columns/PeerList")
	_pin_edit = get_node("Root/Columns/PinEdit")
	_send_btn = get_node("Root/Columns/SendBtn")
	_log = get_node("Root/Columns/SyncLog")
	_status_label = get_node("Root/StatusLabel")
	_discovery_btn.toggled.connect(_on_discovery_toggled)
	_send_btn.pressed.connect(_on_send)
	_pin_edit.text_changed.connect(func(value: String):
		if value.strip_edges() != "" and _service != null:
			_service.set_pin(value.strip_edges()))
	title = "LAN Sync"
	# fit small screens: the fixed 720x460 overflows portrait phones
	var vp: Vector2i = get_viewport().get_visible_rect().size
	var narrow := vp.x < 700
	var dialog_w := mini(720, int(vp.x * (0.86 if narrow else 0.92)))
	var dialog_h := mini(640 if narrow else 460, int(vp.y * (0.84 if narrow else 0.70)))
	size = Vector2i(maxi(260, dialog_w), maxi(360, dialog_h))
	var pal: Dictionary = GameManager.palette()
	var panel := StyleBoxFlat.new()
	panel.bg_color = pal.get("panel", Color("1d0d3a"))
	panel.border_color = pal.get("accent4", Color("8a2be2"))
	panel.set_border_width_all(1)
	panel.corner_radius_top_left = 8
	panel.corner_radius_top_right = 8
	panel.corner_radius_bottom_left = 8
	panel.corner_radius_bottom_right = 8
	add_theme_stylebox_override("panel", panel)
	add_theme_color_override("font_color", pal.get("text", Color.WHITE))

	_pin_label.text = "PIN: " + (GameManager.sync_pin if GameManager.sync_pin != "" else "Not set")
	_pin_edit.text = GameManager.sync_pin
	_service = service if service != null else SyncService.new()
	_service.name = "SyncService"
	_service.set_pin(GameManager.sync_pin)
	add_child(_service)
	_service.peers_changed.connect(_refresh_peers)
	_service.sync_done.connect(_on_sync_done)
	_service.sync_failed.connect(_on_sync_failed)

	_device_label.text = "Device: " + _service.device_name + "\nID: " + GameManager.device_id
	_log.append_text("[color=%s]LAN Sync ready. Start discovery to find peers, then share your PIN to pair. Devices you've paired with before reconnect without a PIN.[/color]\n" % _css(pal.get("accent2", Color.GRAY)))

func _css(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]

func _on_discovery_toggled(pressed: bool) -> void:
	if pressed:
		if _service.start_discovery():
			_service.enable_auto_sync()
			_discovery_btn.text = "Stop Discovery"
			var pin := GameManager.sync_pin
			if pin == "":
				pin = _service.gen_pin()
				_service.set_pin(pin)
			_pin_label.text = "PIN: " + pin
			_log.append_text("[color=%s]Discovery started. PIN: %s. Looking for devices on this LAN…[/color]\n" % [_css(Color.WHITE), pin])
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
		var peer_id := str(p.get("id", ""))
		_peer_list.add_item("◆ %s\n%s" % [str(p["name"]), peer_id])
		_peer_list.set_item_metadata(i, ip)
		if ip == selected_ip:
			_peer_list.select(i)
		i += 1

func _on_send() -> void:
	var sel := _peer_list.get_selected_items()
	if sel.size() == 0:
		_status_label.text = "Select a peer first."
		return
	var pin := _pin_edit.text.strip_edges()
	if pin == "":
		_status_label.text = "Enter the remote PIN."
		return
	var ip := str(_peer_list.get_item_metadata(sel[0]))
	var p: Dictionary = _service.peers.get(ip, {})
	var port := int(p.get("tcp", SyncService.TCP_PORT))
	var peer_name := str(p.get("name", ip))
	var files: Dictionary = _service.collect_notes()["files"]
	if files.is_empty():
		_status_label.text = "No notes to send."
		return
	_status_label.text = "Sending %d notes to %s..." % [files.size(), peer_name]
	_send_btn.disabled = true
	await get_tree().process_frame
	var res: Dictionary = await _send_task(ip, port, pin, files, peer_name)
	_send_btn.disabled = false
	_status_label.text = str(res.get("msg", ""))

func _send_task(ip: String, port: int, pin: String, files: Dictionary, peer_name: String) -> Dictionary:
	var res := SyncService.push_to(ip, port, pin, files)
	if res.get("ok", false):
		var count := int(res.get("count", 0))
		_log.append_text("[color=green]Sent %d notes to %s[/color]\n" % [count, peer_name])
		return {"msg": "Sent %d notes to %s." % [count, peer_name]}
	else:
		_log.append_text("[color=red]Send to %s failed: %s[/color]\n" % [peer_name, str(res.get("error", "?"))])
		return {"msg": "Send failed: %s" % str(res.get("error", "?"))}

func _on_sync_done(peer_name: String, count: int) -> void:
	_log.append_text("[color=green]Received %d notes from %s[/color]\n" % [count, peer_name])

func _on_sync_failed(reason: String) -> void:
	_log.append_text("[color=red]Sync failed: %s[/color]\n" % reason)
