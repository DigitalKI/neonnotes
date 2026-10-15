class_name ShareIntake
extends Node
## Receives data shared INTO NeonNotes from the OS share sheet and files it in
## the Inbox through Capture — the same entry point the in-app Capture page uses.
##
## The share-target itself comes from addons/SharePlugin, whose `Share` node is
## created only where its singleton actually exists (an exported Android/iOS
## build). On desktop nothing is instantiated, so a normal run, the smoke test
## and the unit suite stay plugin-free and log no error.
##
## `handle_payload()` is deliberately plugin-independent (untyped duck typing on
## the plugin's ReceivedSharedData), so the routing can be exercised hermetically
## without an Android device.

## Emitted once per received share with the Inbox notes that were created.
signal received(rels: Array[String])
## Emitted with a short status line for the status bar.
signal intake_message(msg: String)

const SharePluginScript := preload("res://addons/SharePlugin/Share.gd")

## The plugin's Share node, or null when the platform has no SharePlugin.
var share_node: Node


## True when the OS share sheet can hand data to this app right now.
func is_available() -> bool:
	return Engine.has_singleton("SharePlugin")


## Create (once) and enable/disable the share-target. No-op off-platform.
func start(enabled: bool) -> void:
	if not is_available():
		return
	if share_node == null:
		share_node = SharePluginScript.new()
		share_node.name = "ShareTarget"
		add_child(share_node)
		share_node.share_received.connect(_on_share_received)
	share_node.set_share_target(enabled)


func set_enabled(enabled: bool) -> void:
	if share_node != null:
		share_node.set_share_target(enabled)


func _on_share_received(data) -> void:
	if data != null:
		handle_payload(data)


## Route one received payload into Inbox. Returns the relative path of the last
## capture ("" when nothing usable arrived); `received` carries every note made.
func handle_payload(data) -> String:
	var made: Array[String] = []
	# Files first: a link share carries the page title as subject, and an image
	# share often carries no text at all.
	if data.has_files():
		for path in data.get_file_paths():
			var rel_file := _capture_file(String(path), str(data.get_subject()))
			if rel_file != "":
				made.append(rel_file)
	if data.has_text():
		var rel_text := _capture_text(str(data.get_text()), str(data.get_subject()))
		if rel_text != "":
			made.append(rel_text)
	if made.is_empty():
		intake_message.emit("✗ Nothing to capture from the share")
		return ""
	received.emit(made)
	intake_message.emit("📥 Shared into Inbox (%d)" % made.size() if made.size() > 1 else "📥 Shared into Inbox")
	return made[made.size() - 1]


## A shared link arrives as EXTRA_TEXT (the URL) with EXTRA_SUBJECT carrying the
## page title, so the subject becomes the note title. capture_link() falls back
## to plain text for anything that is not a URL.
func _capture_text(text: String, subject: String) -> String:
	var opts := {}
	var title := subject.strip_edges()
	if title != "":
		opts["title"] = title
	return Capture.capture_link(text, opts)


## Images are imported into vault/media/ and embedded; other files cannot be
## embedded, so a note records what arrived instead of dropping it silently.
## (The plugin copies received files into the app cache, so their path is
## temporary — hence no `source:`.)
func _capture_file(path: String, subject: String) -> String:
	if path == "":
		return ""
	var name := path.get_file()
	var title := subject.strip_edges()
	if title == "":
		title = name.get_basename()
	if path.get_extension().to_lower() in MediaImport.IMAGE_EXTS:
		return Capture.capture_image(path, {"title": title})
	return Capture.capture_text("Shared file: **%s**" % name, {"title": title})
