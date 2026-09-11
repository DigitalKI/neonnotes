class_name SyncDialog
extends AcceptDialog

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
	title = "LAN Sync"
	size = Vector2i(720, 460)
	var pal: Dictionary = GameManager.palette()

	var root := VBoxContainer.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var device_row := HBoxContainer.new()
	device_row.name = "DeviceRow"
	device_row.add_theme_constant_override("separation", 16)
	root.add_child(device_row)

	_device_label = Label.new()
	_device_label.name = "DeviceLabel"
	device_row.add_child(_device_label)

	_pin_label = Label.new()
	_pin_label.name = "PinLabel"
	_pin_label.add_theme_font_override("font", load("res://assets/fonts/Orbitron.ttf"))
	_pin_label.add_theme_font_size_override("font_size", 28)
	_pin_label.add_theme_color_override("font_color", pal.get("accent", Color.CYAN))
	device_row.add_child(_pin_label)

	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 12)
	root.add_child(columns)

	var left := VBoxContainer.new()
	left.name = "LeftCol"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	columns.add_child(left)

	_discovery_btn = Button.new()
	_discovery_btn.name = "DiscoveryToggle"
	_discovery_btn.toggle_mode = true
	_discovery_btn.text = "Start Discovery"
	_discovery_btn.toggled.connect(_on_discovery_toggled)
	left.add_child(_discovery_btn)

	_peer_list = ItemList.new()
	_peer_list.name = "PeerList"
	_peer_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_peer_list)

	_pin_edit = LineEdit.new()
	_pin_edit.name = "PinEdit"
	_pin_edit.placeholder_text = "Remote PIN or word-code"
	left.add_child(_pin_edit)

	_send_btn = Button.new()
	_send_btn.name = "SendBtn"
	_send_btn.text = "Send Notes → Peer"
	_send_btn.pressed.connect(_on_send)
	left.add_child(_send_btn)

	var right := VBoxContainer.new()
	right.name = "RightCol"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)

	_log = RichTextLabel.new()
	_log.name = "SyncLog"
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_color_override("default_color", pal.get("text", Color.WHITE))
	right.add_child(_log)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	root.add_child(_status_label)

	_service = SyncService.new()
	_service.name = "SyncService"
	add_child(_service)
	_service.peers_changed.connect(_refresh_peers)
	_service.sync_done.connect(_on_sync_done)
	_service.sync_failed.connect(_on_sync_failed)

	_device_label.text = "Device: " + _service.device_name
	_log.append_text("[color=%s]LAN Sync ready. Start discovery to find peers, then share your PIN to pair.[/color]\n" % _css(pal.get("accent2", Color.GRAY)))

func _css(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]

func _on_discovery_toggled(pressed: bool) -> void:
	if pressed:
		if _service.start_discovery():
			_discovery_btn.text = "Stop Discovery"
			var pin := _service.gen_pin()
			_service.set_pin(pin)
			_pin_label.text = pin
			_log.append_text("[color=%s]Discovery started. PIN: %s[/color]\n" % [_css(Color.WHITE), pin])
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
	var idx := _peer_list.get_selected_items()
	if idx.size() > 0:
		selected_ip = _peer_list.get_item_metadata(idx[0])
	_peer_list.clear()
	var i := 0
	for ip in _service.peers.keys():
		var p: Dictionary = _service.peers[ip]
		_peer_list.add_item("%s  (%s)" % [str(p["name"]), ip])
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
	var files := _service.collect_notes()
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
