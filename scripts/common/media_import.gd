class_name MediaImport
extends RefCounted
## Media library + image import helpers extracted from main.gd (2026-09-29).
## All functions are static; directory paths are passed in so this class owns
## no app state. Image bytes are decoded by file signature (magic bytes) so
## the source never has to be trusted for its name or extension — mirrors the
## approach used across the Godot community for Android SAF (Storage Access
## Framework) URIs.

const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "gif"]


## Remove empty (0-byte) and corrupt/undecodable media files. Sync/import
## failures can leave empty media files behind. Clean these up before building
## the library so broken entries are never presented.
static func cleanup_empty_media(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for name in dir.get_files():
		var path := dir_path.path_join(name)
		var file := FileAccess.open(path, FileAccess.READ)
		var file_size := file.get_length() if file != null else 0
		if file != null:
			file.close()
		if file_size <= 0:
			DirAccess.remove_absolute(path)
			continue
		# Loading through Godot validates the actual image payload, not just its
		# extension. Remove truncated/corrupt media that cannot be decoded.
		if Image.load_from_file(path) == null:
			DirAccess.remove_absolute(path)


## Sorted list of image file paths directly inside the media directory.
static func collect_media_images(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for name in dir.get_files():
		if name.get_extension().to_lower() in IMAGE_EXTS:
			out.append(dir_path.path_join(name))
	out.sort()
	return out


## Copy an Android content:// URI (SAF provider stream) to the vault, always
## re-encoding as PNG. flash_cb is called with a user-facing message when the
## payload cannot be decoded.
static func copy_android_content_uri(uri_text: String, dest: String, flash_cb: Callable = Callable()) -> bool:
	print("[NN image] importing content URI")
	# Canonical Godot 4 Android approach: FileAccess.open() resolves content://
	# URIs through Android's own content resolver, so no Java/JNI plumbing is
	# needed. (This code only runs on Android; the desktop build compiles it out.)
	# Godot 4.6+ ships SAF support; the community flow calls
	# AndroidRuntime.updatePersistableUriPermission(uri, true) so the granted
	# URI stays readable for this session (see godot-proposals #14263 / #12669).
	if OS.get_name() == "Android" and Engine.has_singleton("AndroidRuntime"):
		var rt: Variant = Engine.get_singleton("AndroidRuntime")
		rt.call("updatePersistableUriPermission", uri_text, true)
	var f := FileAccess.open(uri_text, FileAccess.READ)
	if f == null:
		print("[NN image] could not open content URI")
		return false
	var bytes := f.get_buffer(f.get_length())
	f.close()
	print("[NN image] content bytes=%d" % bytes.size())
	if bytes.is_empty():
		return false
	var img := decode_image(bytes)
	if img == null:
		print("[NN image] unsupported image format")
		if flash_cb.is_valid():
			flash_cb.call("✗ Unsupported image format (try JPG or PNG)")
		return false
	var save_result := img.save_png(dest)
	print("[NN image] saved='%s' result=%s" % [dest, save_result])
	return save_result == OK


## Inspect the raw image bytes and dispatch to the matching decoder by file
## signature (magic bytes), so the source never has to be trusted for its name
## or extension.
static func decode_image(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var magic := bytes.slice(0, min(12, bytes.size()))
	# PNG 89 50 4E 47 0D 0A 1A 0A
	if magic == bytes.slice(0, min(8, bytes.size())) and bytes.size() >= 8 \
			and magic[0] == 0x89 and magic[1] == 0x50 and magic[2] == 0x4E and magic[3] == 0x47:
		return img if img.load_png_from_buffer(bytes) == OK else null
	# JPEG FF D8 FF
	if bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return img if img.load_jpg_from_buffer(bytes) == OK else null
	# WebP RIFF....WEBP
	if bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 \
			and bytes[3] == 0x46 and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		return img if img.load_webp_from_buffer(bytes) == OK else null
	# GIF87a / GIF89a
	if bytes.size() >= 6 and bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46:
		return img if img.load_gif_from_buffer(bytes) == OK else null
	# Fallback: let Godot probe based on its own internal heuristics.
	if img.load_jpg_from_buffer(bytes) == OK:
		return img
	if img.load_png_from_buffer(bytes) == OK:
		return img
	if img.load_webp_from_buffer(bytes) == OK:
		return img
	if img.load_gif_from_buffer(bytes) == OK:
		return img
	return null


## Compute a unique destination path inside the vault's media directory for an
## imported image. Android SAF may deliver a path we cannot trust for its real
## extension (folder-dependent virtual names like `image%3A2117.`); the name is
## decoded and sanitized, and collisions get a numeric suffix. Content-URI
## imports are always re-encoded with save_png(), so the destination always
## gets a PNG suffix — a PNG payload saved as `photo.jpg` would otherwise be
## loaded according to the wrong extension and not render.
static func media_dest_for(media_dir: String, source_name: String, is_content_uri: bool) -> String:
	var raw_ext := source_name.get_extension().to_lower()
	if raw_ext not in IMAGE_EXTS:
		raw_ext = ""
	var decoded_name := source_name.uri_decode()
	var source_ext := decoded_name.get_extension().to_lower()
	var stem := decoded_name
	if source_ext != "":
		stem = decoded_name.substr(0, decoded_name.length() - source_ext.length() - 1)
	stem = stem.replace(":", "-").replace("/", "-").replace("\\", "-")
	var ext := source_ext if source_ext in IMAGE_EXTS else raw_ext
	if is_content_uri:
		ext = "png"
	var dest := media_dir + "/" + stem + ("." + ext if ext != "" else ".png")
	var i := 2
	while FileAccess.file_exists(dest):
		dest = "%s/%s-%d.%s" % [media_dir, stem, i, ext if ext != "" else "png"]
		i += 1
	return dest


## Import an image into dest. Content URIs go through the Android
## ContentResolver; normal files use a direct-copy fast path and fall back to
## decoding + re-encoding so the embed never depends on the source
## folder/name/extension. Returns true when the file landed at dest.
static func import_image(path: String, dest: String, flash_cb: Callable = Callable()) -> bool:
	if path.begins_with("content://"):
		return copy_android_content_uri(path, dest, flash_cb)
	var ext := path.get_extension().to_lower()
	if ext in IMAGE_EXTS and DirAccess.copy_absolute(path, dest) == OK:
		return true
	# Fallback: read the raw bytes directly and decode them.
	var src := FileAccess.open(path, FileAccess.READ)
	if src == null:
		return false
	var imported := decode_image(src.get_buffer(src.get_length()))
	src.close()
	if imported == null:
		return false
	return imported.save_png(dest) == OK
