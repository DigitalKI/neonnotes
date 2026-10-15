class_name OutboundShare
extends RefCounted
## Social sharing & media-library saving, plugin-less (JNI via JavaClassWrapper).
## Named OutboundShare so it does not collide with the node class `Share` from
## addons/SharePlugin (which handles the *incoming* share sheet).
##
## Architecture (per the Android storage design doc):
##   Export -> user://vault file
##   Save   -> MediaStore insert (Pictures/NeonNotes) -> content:// URI,
##             which lands the file in the device media library / gallery.
##   Share  -> ACTION_SEND with the content:// URI + FLAG_GRANT_READ_URI_PERMISSION,
##             letting the Android share sheet hand it to any target app.
##   Desktop -> falls back to copying into Pictures/Downloads and shell_open.

## App subfolder inside the device media library.
const MEDIA_DIR := "Pictures/NeonNotes"

## Share plain text (e.g. markdown)
static func share_text(title: String, text: String) -> bool:
	if OS.get_name() == "Android":
		if _android_share_text(title, text):
			return true
		# fall through to clipboard fallback
		DisplayServer.clipboard_set(text)
		return false
	DisplayServer.clipboard_set(text)
	return false

## Save an image file (PNG/GIF) into the device media library (gallery).
## Android: MediaStore, Pictures/NeonNotes. Desktop: copies to ~/Pictures.
## Returns true if the file landed in shared storage.
static func save_to_gallery(path: String) -> bool:
	if OS.get_name() == "Android":
		return _android_save_to_mediastore(path) != ""
	var pictures := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures.is_empty() or not DirAccess.dir_exists_absolute(pictures):
		pictures = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if pictures.is_empty():
		return false
	var app_dir := pictures + "/NeonNotes"
	DirAccess.make_dir_recursive_absolute(app_dir)
	var dest := app_dir + "/" + path.get_file()
	return _copy_file(path, dest)

## Share an image file (PNG/GIF). On Android this first registers the file
## with MediaStore (so it also lands in the media library) and then opens the
## system share sheet with a content:// URI. Returns true if handed to the OS.
static func share_image(path: String) -> bool:
	if OS.get_name() == "Android":
		if _android_share_image(path):
			return true
		# Fallback: put the file somewhere other apps can reach it manually.
		if save_to_gallery(path):
			DisplayServer.clipboard_set(path.get_file())
			return true
		return false
	OS.shell_open(ProjectSettings.globalize_path(path).get_base_dir())
	return false

static func mime_of(path: String) -> String:
	match path.get_extension().to_lower():
		"gif": return "image/gif"
		"jpg", "jpeg": return "image/jpeg"
		_: return "image/png"

# ------------------------------------------------------------- Android

## True when the AndroidRuntime singleton (Godot 4.5+) is available.
static func _runtime() -> Variant:
	if OS.get_name() != "Android" or not Engine.has_singleton("AndroidRuntime"):
		return null
	var rt: Variant = Engine.get_singleton("AndroidRuntime")
	if rt == null or rt.call("getActivity") == null:
		return null
	return rt

static func _activity() -> Variant:
	var rt: Variant = _runtime()
	return null if rt == null else rt.call("getActivity")

static func _jni() -> Variant:
	if not ClassDB.class_exists("JavaClassWrapper"):
		return null
	return Engine.get_singleton("JavaClassWrapper")

## Insert the file into MediaStore (Pictures/NeonNotes) and copy its bytes
## into the new entry. Returns the content:// URI string, or "" on failure.
## No IS_PENDING flag is used: the write is a single fast shot, and skipping
## the Integer-overloaded ContentValues.put keeps the JNI surface simple
## (and keeps pre-API-29 devices working).
static func _android_save_to_mediastore(path: String) -> String:
	var activity: Variant = _activity()
	var jcw: Variant = _jni()
	if activity == null or jcw == null:
		return ""
	var resolver: Variant = activity.call("getContentResolver")
	# Avoid JavaClass static-field access here. Godot 4.7's JavaClassWrapper
	# does not expose MediaStore.Images.Media.EXTERNAL_CONTENT_URI as a
	# readable property. This is the canonical external-images URI and is
	# equivalent to that Android static field.
	var uri_cls: Variant = jcw.call("wrap", "android.net.Uri")
	var values_cls: Variant = jcw.call("wrap", "android.content.ContentValues")
	if resolver == null or uri_cls == null or values_cls == null:
		return ""
	var external_images_uri: Variant = uri_cls.call("parse", "content://media/external/images/media")
	if external_images_uri == null:
		return ""
	var values: Variant = values_cls.call("ContentValues")
	if values == null:
		return ""
	values.call("put", "_display_name", path.get_file())
	values.call("put", "mime_type", mime_of(path))
	var version_cls: Variant = jcw.call("wrap", "android.os.Build$VERSION")
	if version_cls != null:
		var sdk: Variant = version_cls.SDK_INT
		if int(sdk) >= 29:
			values.call("put", "relative_path", MEDIA_DIR)
	var content_uri: Variant = resolver.call("insert", external_images_uri, values)
	if content_uri == null:
		push_warning("[Share] MediaStore insert failed for " + path)
		return ""
	var out: Variant = resolver.call("openOutputStream", content_uri)
	var src := FileAccess.open(path, FileAccess.READ)
	if out == null or src == null:
		return ""
	out.call("write", src.get_buffer(src.get_length()))
	out.call("flush")
	out.call("close")
	src.close()
	return str(content_uri.call("toString"))

static func _android_share_text(title: String, text: String) -> bool:
	var activity: Variant = _activity()
	var jcw: Variant = _jni()
	if activity == null or jcw == null:
		return false
	var intent_cls: Variant = jcw.call("wrap", "android.content.Intent")
	if intent_cls == null:
		return false
	var intent: Variant = intent_cls.call("Intent")
	if intent == null:
		return false
	intent.call("setAction", intent_cls.ACTION_SEND)
	intent.call("setType", "text/plain")
	intent.call("putExtra", "android.intent.extra.TEXT", text)
	var chooser: Variant = intent_cls.call("createChooser", intent, title)
	if chooser == null:
		return false
	activity.call("startActivity", chooser)
	return true

static func _android_share_image(path: String) -> bool:
	var activity: Variant = _activity()
	var jcw: Variant = _jni()
	if activity == null or jcw == null:
		return false
	# Save to the media library first; the resulting content:// URI is what
	# we hand to the share sheet (never a file:// URI).
	var uri_str := _android_save_to_mediastore(path)
	if uri_str.is_empty():
		return false
	var uri_cls: Variant = jcw.call("wrap", "android.net.Uri")
	var intent_cls: Variant = jcw.call("wrap", "android.content.Intent")
	if uri_cls == null or intent_cls == null:
		return false
	var uri: Variant = uri_cls.call("parse", uri_str)
	var intent: Variant = intent_cls.call("Intent")
	if uri == null or intent == null:
		return false
	intent.call("setAction", intent_cls.ACTION_SEND)
	intent.call("setType", mime_of(path))
	intent.call("putExtra", intent_cls.EXTRA_STREAM, uri)
	intent.call("addFlags", int(intent_cls.FLAG_GRANT_READ_URI_PERMISSION))
	var chooser: Variant = intent_cls.call("createChooser", intent, "Share " + path.get_file())
	if chooser == null:
		return false
	activity.call("startActivity", chooser)
	return true

# ------------------------------------------------------------- Common

static func _copy_file(src_path: String, dest_path: String) -> bool:
	var src := FileAccess.open(src_path, FileAccess.READ)
	if src == null:
		return false
	var dest := FileAccess.open(dest_path, FileAccess.WRITE)
	if dest == null:
		src.close()
		return false
	dest.store_buffer(src.get_buffer(src.get_length()))
	dest.close()
	src.close()
	return true
