class_name StatusBarComponent
extends PanelContainer
## Compact status bar with a tiny sync health indicator.
@onready var label: Label = %StatusLabel
@onready var _sync_dot: Label = %SyncStatus
var sync_service: SyncService

func _ready() -> void:
	set_sync_service(null)

func set_sync_service(service: SyncService) -> void:
	sync_service = service
	if service == null:
		_set_dot(Color.DIM_GRAY)
		return
	if not service.sync_done.is_connected(_on_sync_done):
		service.sync_done.connect(_on_sync_done)
	if not service.sync_failed.is_connected(_on_sync_failed):
		service.sync_failed.connect(_on_sync_failed)
	if not service.sync_pending.is_connected(_on_sync_pending):
		service.sync_pending.connect(_on_sync_pending)
	if not GameManager.trusted.is_empty() or not GameManager.paired_peers.is_empty() or GameManager.paired_vault_id != "":
		_set_dot(Color.INDIAN_RED)
	else:
		_set_dot(Color.DIM_GRAY)

func _set_dot(color: Color) -> void:
	if _sync_dot:
		_sync_dot.add_theme_color_override("font_color", color)

func _on_sync_done(_peer: String, _count: int) -> void:
	_set_dot(Color.LIME_GREEN)

func _on_sync_pending() -> void:
	_set_dot(Color.GOLD)

func _on_sync_failed(_reason: String) -> void:
	_set_dot(Color.INDIAN_RED)

func flash(msg: String) -> void:
	label.text = msg
	var tw := create_tween()
	tw.tween_interval(2.5)
	tw.tween_callback(func(): label.text = "Ready")
