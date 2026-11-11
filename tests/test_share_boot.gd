extends Node
## Share cold start on the real shell. The contract:
##   * a pending cold-start payload HOLDS the boot start page — with "open to
##     graph" the whole map would otherwise be built (and rendered a frame or
##     two) only to be torn down when the payload lands one frame later;
##   * the capture landing is the start page that does open;
##   * a payload that produces nothing (refused/empty/silent failure) settles
##     back into the normal start page instead of a blank shell;
##   * the rescan afterwards is targeted (paths + payload notes + metadata-pass
##     restart), not a whole-vault metadata read.
## Plugin-free: ShareIntake.handle_payload() routes without the plugin, and the
## pending flag comes from a stand-in overriding has_pending_payload().
## Vault safety: vault_dir assigned directly (never set_vault_dir — that
## persists) and settings writes suppressed for the whole run.

const ReceivedScript := preload("res://addons/SharePlugin/model/ReceivedSharedData.gd")


## Stand-in for the plugin-backed ShareIntake. `pending` follows the real
## Share.gd lifecycle: true while the consumed intent waits for the
## one-frame-deferred emission, false once emitted (even when the payload
## produced nothing — Share clears _cold_pending at emit time).
class PendingIntake extends ShareIntake:
	var pending := true
	func has_pending_payload() -> bool:
		return pending


class QuietIntake extends ShareIntake:
	func has_pending_payload() -> bool:
		return false


var _fails := 0
var _metadata_fired := false


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	GameManager.metadata_ready.connect(func(): _metadata_fired = true)
	var original_vault := GameManager.vault_dir
	var original_save := GameManager.suppress_settings_save
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://neonnotes-share-boot-test"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("seed.md", "---\ntitle: \"Seed\"\n---\n\nground truth\n")
	GameManager.write_note("other.md", "---\ntitle: \"Other\"\n---\n\nanother note\n")
	GameManager.scan_notes()
	# The expensive start page: with "open to graph" a share cold start used to
	# build the whole map before discarding it.
	GameManager.open_start_mode = "graph"
	GameManager.last_opened_rel = ""
	GameManager.graph_view_state = {}

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	# Baseline: no pending payload → the graph start page really opened.
	_check("start page opened without a pending payload",
		main.graph_view.visible and main.page_mode == "")

	# ---------------- pending payload: hold, land, targeted rescan
	var intake := PendingIntake.new()
	intake.name = "PendingShareIntake"
	main.get_node("ShareIntake").queue_free()
	main.share_intake = intake  # must be in place before the (deferred) open
	intake.received.connect(main._on_share_received)
	# Reset to the state a fresh (held) boot has: the first boot above opened
	# the graph under the un-stubbed intake.
	main.graph_shell.set_graph_state(0)
	GameManager.current_rel = ""
	GameManager.current_file = ""
	main.editor.clear_document()
	main._open_start_page()
	_check("start page held while a payload is pending",
		not main.graph_view.visible and main.page_mode == "")
	_check("nothing loaded behind the hold", GameManager.current_rel == "")

	# One frame later the plugin re-emits; here ShareIntake routes the payload
	# (real capture → real rescan → the Inbox note becomes the landing).
	_metadata_fired = false
	var rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "text/plain",
		"text": "https://example.org/cold-start",
		"subject": "Shared Cold Body",
		"file_paths": PackedStringArray(),
	}))
	await get_tree().process_frame
	_check("capture lands as the start page", GameManager.current_rel == rel
		and rel.begins_with("Inbox/"))
	_check("landing note shows the shared content",
		main.code_edit.text.contains("https://example.org/cold-start"))
	_check("start page still never built for a landed payload",
		not main.graph_view.visible and main.page_mode == "")
	# Share cleared the pending flag when the deferred emission fired.
	intake.pending = false

	# The targeted rescan: the payload metadata is indexed, the restarted
	# metadata pass re-applies everything (metadata_ready), links ready again.
	for i in range(4):
		await get_tree().process_frame
	_check("payload note indexed by the targeted rescan",
		GameManager.titles.get(rel, "") == "Shared Cold Body"
		and GameManager.notes.has(rel))
	_check("metadata pass restarted after the rescan",
		GameManager.links_ready and _metadata_fired)
	_check("seed note metadata survived the rescan",
		GameManager.titles.get("seed.md", "") == "Seed")
	_check("Inbox badge sees the capture", GameManager.inbox_notes().has(rel))

	# ---------------- no-produce payload: hold settles into a start page
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = "seed.md"
	intake.pending = true
	main._open_start_page()  # the stand-in still reports a pending payload
	_check("hold armed again for the second boot", main._share_boot_hold
		and GameManager.current_rel != "seed.md")
	# The payload was emitted and made nothing: Share cleared pending at emit
	# time (received never fired, only the refusal message did).
	intake.pending = false
	for i in range(4):
		await get_tree().process_frame
	_check("silent payload settles into the normal start page",
		GameManager.current_rel == "seed.md" and not main._share_boot_hold)

	# ---------------- no pending: opens immediately
	GameManager.last_opened_rel = "other.md"
	main.share_intake = QuietIntake.new()
	main._open_start_page()
	_check("without a pending payload the start page opens at once",
		GameManager.current_rel == "other.md")

	GameManager.vault_dir = original_vault
	GameManager.suppress_settings_save = original_save
	print("SHARE BOOT RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
