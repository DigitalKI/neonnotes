extends Node
## Dev-only boot profiler: boots the real Main.tscn once against a scratch
## vault and reports where the boot time goes. CPU costs only under --headless
## (the dummy renderer skips GPU/shader work, so use a real device run for
## on-device totals — NEONNOTES_BOOT_DEBUG=1 makes a release build print marks).
##
##   NEONNOTES_VAULT=/tmp/nn-boot-vault NEONNOTES_BOOT_DEBUG=1 \
##       godot --headless --path . scenes/dev/BootBench.tscn
##
## Env:
##   NN_START=last|homepage|graph  start-mode override (default "last"; the
##                                 bench clears last_opened_rel so "last" falls
##                                 back to the homepage note)
##   NN_NOTE=<rel>                 note to pretend was last opened (real "last")
##   NN_SHARE=1                    deliver a synthetic share payload like the
##                                 real plugin: intake swapped for a plugin-
##                                 backed stand-in, payload deferred into the
##                                 same boot flush one slot after the (held)
##                                 start page
##   NN_FRAMES=120                 idle frames to run before quitting
##
## Without NN_SHARE the bench also micro-times the full rescan (`scan_notes`)
## against its parts (`scan_paths` + a warm cached-metadata pass) — the delta
## that a share cold start pays for its rescan today.
##
## Not part of the app; safe to delete.

var _t0 := 0
var _main: Node
var _share_done := false
var _last_frame_t := 0
var _slow_frames: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _micro_done := false
var _frame_no := 0
var _payload: FakePayload


## Plugin-free fake of the SharePlugin payload (same duck-typed surface
## ShareIntake.handle_payload() reads; see ReceivedSharedData).
class FakePayload:
	var text: String
	func get_mime_type() -> String: return "text/plain"
	func has_files() -> bool: return false
	func get_file_paths() -> PackedStringArray: return PackedStringArray()
	func has_text() -> bool: return true
	func get_text() -> String: return text
	func get_subject() -> String: return ""


## Plugin-backed ShareIntake stand-in: reports the cold-start pending payload
## like Share.gd does between consuming the intent and its one-frame emission,
## so NN_SHARE=1 measures the real held-start-page cold start. Like the real
## Share, the flag clears once the payload is (re-)emitted — a first payload
## handled here IS the queued one.
class PendingShareIntake extends ShareIntake:
	var pending := true
	func has_pending_payload() -> bool:
		return pending
	func handle_payload(data) -> String:
		pending = false
		return super.handle_payload(data)


func _ready() -> void:
	var mode := OS.get_environment("NN_START")
	if mode in ["last", "homepage", "graph"]:
		GameManager.open_start_mode = mode
	GameManager.last_opened_rel = OS.get_environment("NN_NOTE")
	GameManager.graph_view_state = {}
	GameManager.metadata_ready.connect(_on_metadata_ready)
	_t0 = Time.get_ticks_msec()
	_last_frame_t = _t0
	_main = load("res://scenes/main/Main.tscn").instantiate()
	add_child(_main)
	# A plugin-backed cold start answers has_pending_payload() during boot, so
	# swap the intake in before the deferred _open_start_page reaches the flush,
	# and wire its signals exactly like Main._phase_share does.
	if OS.get_environment("NN_SHARE") == "1":
		var intake := PendingShareIntake.new()
		_main.share_intake = intake
		intake.received.connect(_main._on_share_received)
		intake.intake_message.connect(_main._flash)
		_payload = FakePayload.new()
		_payload.text = "https://example.org/a-very-hot-article?utm=share #later"
		_deliver_share.call_deferred()


func _on_metadata_ready() -> void:
	_events.append({"t": Time.get_ticks_msec() - _t0, "label": "metadata_ready"})


## Deliver the share payload like the real plugin does: deferred, so it lands in
## the same flush as the held start page (one slot after _open_start_page).
func _deliver_share() -> void:
	var intake: Node = _main.share_intake
	var t := Time.get_ticks_msec()
	intake.handle_payload(_payload)
	var total := Time.get_ticks_msec() - t
	print("[bench] share payload handled: %d ms (ended + %d ms) — capture+rescan+tree+note-open" % [total, Time.get_ticks_msec() - _t0])


func _process(_delta: float) -> void:
	_frame_no += 1
	var frame := _frame_no
	var now := Time.get_ticks_msec()
	var frame_ms := now - _last_frame_t
	_last_frame_t = now
	_events.append({"t": now - _t0, "label": "frame %d start" % frame})
	if frame_ms > 6:
		_slow_frames.append({"frame": frame, "ms": frame_ms})
	if frame == 1:
		print("[bench] first _process + %d ms" % (now - _t0))
	if not OS.get_environment("NN_SHARE") == "1" and not _micro_done and GameManager.links_ready:
		_micro_done = true
		_micro_rescans()
	var frames := int(OS.get_environment("NN_FRAMES")) if OS.get_environment("NN_FRAMES") != "" else 120
	if frame >= frames:
		_report(frames)


func _micro_rescans() -> void:
	var count := GameManager.notes.size()
	var t := Time.get_ticks_msec()
	GameManager.scan_paths()
	var t_paths := Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	for n in GameManager.notes:
		GameManager._apply_cached_meta(n)
	var t_warm := Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	GameManager.scan_notes()
	var t_full := Time.get_ticks_msec() - t
	print("[bench] rescan %d notes: scan_paths %d ms · cache-warm metadata pass %d ms · full scan_notes %d ms" %
			[count, t_paths, t_warm, t_full])
	print("[bench]   → share cold start pays the full pass; a targeted rescan pays only paths+new-note reads")


func _report(frames: int) -> void:
	var total := Time.get_ticks_msec() - _t0
	print("---- bench report ----")
	_events.sort_custom(func(a, b): return int(a["t"]) < int(b["t"]))
	for e in _events:
		print("[bench] + %5d ms  %s" % [int(e["t"]), e["label"]])
	_slow_frames.sort_custom(func(a, b): return int(b["ms"]) < int(a["ms"]))
	print("[bench] slowest frames over %d frames:" % frames)
	for i in range(mini(8, _slow_frames.size())):
		print("[bench]   frame %5d — %5d ms" % [int(_slow_frames[i]["frame"]), int(_slow_frames[i]["ms"])])
	print("[bench] total after %d frames: %d ms" % [frames, total])
	get_tree().quit()
