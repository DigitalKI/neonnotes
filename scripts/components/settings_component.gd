class_name SettingsComponent
extends VBoxContainer

signal close_requested

@onready var vault_path: Label = %VaultPath
@onready var paired_devices: Label = %PairedDevices
@onready var graph_levels: SpinBox = %GraphLevels
@onready var style: OptionButton = %Style
@onready var font_opt: OptionButton = %Font
@onready var font_size: SpinBox = %FontSize
@onready var auto_ui_scale: CheckButton = %AutoUiScale
@onready var ui_scale: SpinBox = %UiScale
@onready var ui_scale_hint: Label = %UiScaleHint
@onready var vault_button: Button = %VaultButton
@onready var sync_button: Button = %SyncButton
@onready var close_button: Button = %CloseButton
@onready var crt_ui: CheckButton = %CrtUi
@onready var crt_export: CheckButton = %CrtExport
@onready var open_start: OptionButton = %OpenStart

var vault_cb: Callable
var sync_cb: Callable

func _ready() -> void:
	vault_button.pressed.connect(func(): vault_cb.call() if vault_cb.is_valid() else null)
	sync_button.pressed.connect(func(): sync_cb.call() if sync_cb.is_valid() else null)
	close_button.pressed.connect(func(): close_requested.emit())
	crt_ui.toggled.connect(_on_crt_ui_toggled)
	crt_export.toggled.connect(_on_crt_export_toggled)
	open_start.add_item("Last opened page")
	open_start.add_item("Homepage")
	open_start.item_selected.connect(_on_open_start_selected)
	graph_levels.value_changed.connect(_on_graph_levels_changed)
	for p in GameManager.PALETTES.keys():
		style.add_item(p)
	style.item_selected.connect(func(i: int): GameManager.set_palette(style.get_item_text(i)))
	for f in GameManager.FONTS.keys():
		font_opt.add_item(f)
	font_opt.item_selected.connect(func(i: int): GameManager.set_font(font_opt.get_item_text(i)))
	font_size.min_value = GameManager.MIN_FONT_SIZE
	font_size.max_value = GameManager.MAX_FONT_SIZE
	font_size.value_changed.connect(func(v: float): GameManager.set_font_size(int(v)))
	auto_ui_scale.toggled.connect(_on_auto_ui_scale_toggled)
	ui_scale.min_value = GameManager.MIN_UI_SCALE_PERCENT
	ui_scale.max_value = GameManager.MAX_UI_SCALE_PERCENT
	ui_scale.value_changed.connect(func(v: float): GameManager.set_ui_scale_percent(int(v)))
	# The scale rows (and the detected-density readout) must track changes made
	# from elsewhere while the page stays open.
	GameManager.ui_scale_changed.connect(_refresh_scale_rows)
	_refresh_scale_rows()

func refresh() -> void:
	vault_path.text = "Vault: " + GameManager.vault_abs() + "\nName: " + GameManager.vault_abs().get_file()
	paired_devices.text = "Sync: %s · paired devices: %s" % [
		GameManager.vault_id if GameManager.vault_id != "" else "(none)",
		(str(GameManager.paired_peers.keys()) if not GameManager.paired_peers.is_empty() else "None")]
	graph_levels.value = GameManager.graph_levels
	style.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))
	font_opt.select(maxi(0, GameManager.FONTS.keys().find(GameManager.font_name)))
	font_size.set_value_no_signal(GameManager.font_size)
	_refresh_scale_rows()
	crt_ui.set_pressed_no_signal(GameManager.crt_ui)
	_sync_crt_export_row()
	open_start.select(0 if GameManager.open_start_mode == "last" else 1)

func _on_auto_ui_scale_toggled(pressed: bool) -> void:
	GameManager.set_auto_ui_scale(pressed)
	_refresh_scale_rows()


## Show the detected display and the scale that follows from it, so a bad DPI
## reading (or an intentional override) is visible instead of a mystery.
func _refresh_scale_rows() -> void:
	if auto_ui_scale == null:
		return
	auto_ui_scale.set_pressed_no_signal(GameManager.auto_ui_scale)
	ui_scale.set_value_no_signal(GameManager.ui_scale_percent)
	var dpi := DisplayServer.screen_get_dpi()
	var detail := ""
	if dpi >= GameManager.MIN_TRUSTED_DPI and dpi <= GameManager.MAX_TRUSTED_DPI:
		detail = "Detected %d dpi" % dpi
		var inches := GameManager.physical_short_side_inches()
		if inches > 0.0:
			detail += " (%.1f in short side)" % inches
	else:
		detail = "Density unavailable — using the default scale"
	ui_scale_hint.text = "%s → ×%.2f applied%s" % [
		detail, GameManager.ui_scale(),
		"" if GameManager.auto_ui_scale else " (automatic off)"]


## Reflect the master switch on the export row: with the UI overlay off, CRT FX
## cannot be exported either, so the control is disabled and shown unchecked.
## The stored per-export preference is left intact and restored on re-enable.
func _sync_crt_export_row() -> void:
	var ui_on := GameManager.crt_ui
	crt_export.disabled = not ui_on
	crt_export.set_pressed_no_signal(ui_on and GameManager.export_crt)

func _on_open_start_selected(index: int) -> void:
	GameManager.open_start_mode = "last" if index == 0 else "homepage"
	GameManager._save_settings()

func _on_graph_levels_changed(value: float) -> void:
	GameManager.graph_levels = clampi(int(value), 1, 10)
	GameManager._save_settings()


func _on_crt_ui_toggled(pressed: bool) -> void:
	GameManager.set_crt_ui(pressed)
	_sync_crt_export_row()


func _on_crt_export_toggled(pressed: bool) -> void:
	# The export control is disabled while the master switch is off; ignore any
	# toggle it might still emit so the stored preference is not clobbered.
	if not GameManager.crt_ui:
		return
	GameManager.set_export_crt(pressed)
