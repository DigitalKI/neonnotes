class_name SettingsComponent
extends VBoxContainer

signal close_requested

@onready var vault_path: Label = %VaultPath
@onready var paired_devices: Label = %PairedDevices
@onready var graph_levels: SpinBox = %GraphLevels
@onready var style: OptionButton = %Style
@onready var vault_button: Button = %VaultButton
@onready var sync_button: Button = %SyncButton
@onready var close_button: Button = %CloseButton
@onready var crt_export: CheckButton = %CrtExport
@onready var open_start: OptionButton = %OpenStart

var vault_cb: Callable
var sync_cb: Callable

func _ready() -> void:
	vault_button.pressed.connect(func(): vault_cb.call() if vault_cb.is_valid() else null)
	sync_button.pressed.connect(func(): sync_cb.call() if sync_cb.is_valid() else null)
	close_button.pressed.connect(func(): close_requested.emit())
	crt_export.toggled.connect(_on_crt_export_toggled)
	open_start.add_item("Last opened page")
	open_start.add_item("Homepage")
	open_start.item_selected.connect(_on_open_start_selected)
	graph_levels.value_changed.connect(_on_graph_levels_changed)
	for p in GameManager.PALETTES.keys():
		style.add_item(p)
	style.item_selected.connect(func(i: int): GameManager.set_palette(style.get_item_text(i)))

func refresh() -> void:
	vault_path.text = "Vault: " + GameManager.vault_abs() + "\nName: " + GameManager.vault_abs().get_file()
	paired_devices.text = "Paired devices: " + (str(GameManager.paired_peers.keys()) if not GameManager.paired_peers.is_empty() else "None")
	graph_levels.value = GameManager.graph_levels
	style.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))
	crt_export.button_pressed = GameManager.export_crt
	open_start.select(0 if GameManager.open_start_mode == "last" else 1)

func _on_open_start_selected(index: int) -> void:
	GameManager.open_start_mode = "last" if index == 0 else "homepage"
	GameManager._save_settings()

func _on_graph_levels_changed(value: float) -> void:
	GameManager.graph_levels = clampi(int(value), 1, 10)
	GameManager._save_settings()


func _on_crt_export_toggled(pressed: bool) -> void:
	GameManager.set_export_crt(pressed)
