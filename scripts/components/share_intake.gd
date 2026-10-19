class_name ShareIntake
extends Node
## Receives data shared INTO NeonNotes from the OS share sheet, or opened from
## Android's "Open with" picker, and files it in the Inbox through Capture — the
## same entry point the in-app Capture page uses.
##
## The share-target itself comes from addons/SharePlugin, whose `Share` node is
## created only where its singleton actually exists (an exported Android/iOS
## build). The "Open with" bridge (addons/MarkdownOpen) rewrites ACTION_VIEW as
## ACTION_SEND, so Markdown files arrive through this same path. On desktop
## nothing is instantiated, so a normal run, the smoke test and the unit suite
## stay plugin-free and log no error.
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
		# A mobile build is expected to ship the singleton. Without this warning a
		# plugin that failed to package would silently never appear in the sheet.
		if OS.get_name() in ["Android", "iOS"]:
			push_warning("ShareIntake: SharePlugin singleton missing — enable addons/SharePlugin and export with the Gradle build")
		return
	if share_node == null:
		share_node = SharePluginScript.new()
		share_node.name = "ShareTarget"
		add_child(share_node)
		share_node.share_received.connect(_on_share_received)
	share_node.set_share_target(enabled)
	# The share target is toggled through PackageManager, so the *effective*
	# state is what matters: a mismatch here means no share-sheet entry.
	print("[share] target active=%s (requested %s)" % [share_node.is_share_target(), enabled])


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
	var markdown_count := 0
	var mime_type := str(data.get_mime_type()) if data.has_method("get_mime_type") else ""
	# Files first: a link share carries the page title as subject, and an image
	# share often carries no text at all.
	if data.has_files():
		for path in data.get_file_paths():
			var file_path := String(path)
			var is_md := Capture.is_markdown(file_path, mime_type)
			var rel_file := _capture_file(file_path, mime_type)
			if rel_file != "":
				made.append(rel_file)
				if is_md:
					markdown_count += 1
	if data.has_text():
		var rel_text := _capture_text(str(data.get_text()), str(data.get_subject()))
		if rel_text != "":
			made.append(rel_text)
	if made.is_empty():
		# A refused file already explained itself; only a genuinely empty payload
		# needs the generic message.
		if not data.has_files() and not data.has_text():
			intake_message.emit("✗ Nothing to capture from the share")
		return ""
	received.emit(made)
	if markdown_count > 0 and markdown_count == made.size():
		intake_message.emit("📥 Imported into Inbox (%d)" % made.size() if made.size() > 1 else "📥 Imported into Inbox")
	elif markdown_count > 0:
		intake_message.emit("📥 Added to Inbox (%d)" % made.size())
	else:
		intake_message.emit("📥 Shared into Inbox (%d)" % made.size() if made.size() > 1 else "📥 Shared into Inbox")
	return made[made.size() - 1]


## A LINK share arrives as EXTRA_TEXT (the URL) with EXTRA_SUBJECT carrying the
## page title, so the subject becomes the note title. A TEXT-SELECTION share does
## NOT: Android/Chrome put the share-sheet label ("Share with…") in EXTRA_SUBJECT,
## so trusting it would title the note with that junk. Only use the subject when
## the payload is a URL; otherwise capture_link() derives a title from the text.
func _capture_text(text: String, subject: String) -> String:
	var opts := {}
	if text.begins_with("http://") or text.begins_with("https://"):
		var title := subject.strip_edges()
		if title != "":
			opts["title"] = title
	return Capture.capture_link(text, opts)


## Images are imported into vault/media/ and embedded. Everything else is
## REFUSED rather than noted: the plugin copies a received file into the app's
## cache (getCacheDir()/share_received/), not into the vault, so a note that only
## named it would be a phantom — it looks saved, never syncs, and points at a
## path the OS may delete at any time. The manifest no longer advertises those
## types (see addons/SharePlugin/SharePlugin.gd), so this is the safety net for a
## sender that forces one through.
## The received file name titles an image: Android's EXTRA_SUBJECT for a shared
## file is the same unreliable share-sheet label, so it is not trusted.
func _capture_file(path: String, mime_type: String = "") -> String:
	if path == "":
		return ""
	var file_name := path.get_file()
	var title := file_name.get_basename()
	# A Markdown document (shared or opened from Android's "Open with" picker)
	# is copied into the Inbox unchanged: front matter, wiki-links and body
	# formatting survive, and the original file is never moved.
	if Capture.is_markdown(path, mime_type):
		var rel := Capture.import_markdown(path, {"name": file_name})
		if rel == "":
			intake_message.emit("✗ Couldn't read %s" % file_name)
		return rel
	if path.get_extension().to_lower() in MediaImport.IMAGE_EXTS:
		var rel := Capture.capture_image(path, {"title": title})
		if rel == "":
			intake_message.emit("✗ Couldn't read the image %s" % file_name)
		return rel
	intake_message.emit("✗ %s can't be stored — NeonNotes takes links, text, images and Markdown" % file_name)
	return ""
