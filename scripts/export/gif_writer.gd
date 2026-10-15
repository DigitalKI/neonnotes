class_name GifWriter extends RefCounted

## Minimal animated GIF (GIF89a) encoder in pure GDScript.
## Performance: color quantization uses a lazy per-color cache keyed by
## 5-bit-per-channel RGB, so each unique color is matched against the
## palette only once (shared across all frames) instead of scanning the
## full palette for every pixel of every frame.

static func write(path: String, frames: Array[Image], delay_cs: int, palette_colors: PackedColorArray, delays: Array = []) -> bool:
	if frames.is_empty():
		return false
	var first: Image = frames[0].duplicate()
	first.convert(Image.FORMAT_RGB8)
	var w := first.get_width()
	var h := first.get_height()
	if w <= 0 or h <= 0 or w > 65535 or h > 65535:
		return false
	var palette := _palette(palette_colors)
	var quant_cache := {}  # "r,g,b" (5-bit/channel key) -> nearest palette index
	var out := PackedByteArray()
	for b in "GIF89a".to_ascii_buffer(): out.append(b)
	_put_u16(out, w); _put_u16(out, h)
	out.append(0xF7) # global table, 8-bit color resolution, 256 entries
	out.append(0); out.append(0)
	for c in palette:
		out.append(clampi(int(c.r * 255.0), 0, 255)); out.append(clampi(int(c.g * 255.0), 0, 255)); out.append(clampi(int(c.b * 255.0), 0, 255))
	# Netscape application extension: loop forever.
	out.append_array(PackedByteArray([0x21, 0xff, 0x0b]))
	for b in "NETSCAPE2.0".to_ascii_buffer(): out.append(b)
	out.append_array(PackedByteArray([3, 1, 0, 0, 0]))
	for fi in frames.size():
		var image: Image = frames[fi]
		var rgb := image.duplicate()
		rgb.convert(Image.FORMAT_RGB8)
		if rgb.get_width() != w or rgb.get_height() != h:
			return false
		var indices := _quantize(rgb, quant_cache, palette)
		# Per-frame delay when measured timings were supplied, else the default.
		var frame_delay := delay_cs
		if fi < delays.size() and int(delays[fi]) > 0:
			frame_delay = int(delays[fi])
		# Graphic control extension (no transparency, no disposal method).
		out.append_array(PackedByteArray([0x21, 0xf9]))
		out.append(4); out.append(0)
		_put_u16(out, frame_delay); out.append(0)
		out.append(0)
		# Image descriptor + LZW-compressed indexed pixels.
		out.append_array(PackedByteArray([0x2c, 0, 0, 0, 0]))
		_put_u16(out, w); _put_u16(out, h); out.append(0)
		out.append(8)
		var compressed := _lzw(indices)
		var pos := 0
		while pos < compressed.size():
			var n := mini(255, compressed.size() - pos)
			out.append(n)
			for i in n: out.append(compressed[pos + i])
			pos += n
		out.append(0)
	out.append(0x3b)  # trailer
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(out)
	var ok := file.get_error() == OK
	file.close()
	return ok

static func _palette(input: PackedColorArray) -> PackedColorArray:
	var p := PackedColorArray(input)
	var neon := [Color("#050014"), Color("#15005c"), Color("#ff00a8"), Color("#00e5ff"), Color("#7dff00"), Color("#ff6b00"), Color("#ffffff"), Color("#202040")]
	for c in neon: p.append(c)
	while p.size() < 256: p.append(Color(0, 0, 0))
	if p.size() > 256: p.resize(256)
	return p

## Quantize one frame to palette indices using a shared lazy cache.
## Key: 5-bit-per-channel RGB (32768 buckets) -> nearest palette index.
## Each unique color is scanned against the palette only once; subsequent
## pixels (and later frames) hit the cache, turning O(pixels x palette)
## into O(pixels).
static func _quantize(rgb: Image, cache: Dictionary, palette: PackedColorArray) -> PackedByteArray:
	var w := rgb.get_width()
	var h := rgb.get_height()
	var data := rgb.get_data()  # RGB8: 3 bytes per pixel
	var indices := PackedByteArray()
	indices.resize(w * h)
	for y in h:
		var row_base := y * w
		for x in w:
			var o := (row_base + x) * 3
			var key := (data[o] >> 3) << 10 | (data[o + 1] >> 3) << 5 | (data[o + 2] >> 3)
			var idx: Variant = cache.get(key)
			if idx == null:
				idx = _nearest_rgb(data[o] / 255.0, data[o + 1] / 255.0, data[o + 2] / 255.0, palette)
				cache[key] = idx
			indices[row_base + x] = idx
	return indices

static func _nearest_rgb(r: float, g: float, b: float, palette: PackedColorArray) -> int:
	var best := 0
	var distance := INF
	for i in palette.size():
		var p: Color = palette[i]
		var d := (r - p.r) * (r - p.r) + (g - p.g) * (g - p.g) + (b - p.b) * (b - p.b)
		if d < distance:
			distance = d
			best = i
	return best

static func _put_u16(data: PackedByteArray, value: int) -> void:
	data.append(value & 255); data.append((value >> 8) & 255)

## LZW compression (GIF variant, no early change), adapted from the
## pixel-exact reference implementation in kylesza/godot-gif-exporter
## (MIT). Codes and widths are collected first, then bit-packed LSB-first
## in one place. Two critical GIF quirks:
##   1. The dictionary holds ONLY learned multi-byte entries — seeding it
##      with root codes d[i]=i collides with pair keys (0<<8)|v and drops
##      pixels (this was the "black screen with dots" bug).
##   2. Widen the code width at next_code == 2^code_size + 1, NOT 2^code_size:
##      the decoder runs one table entry behind the encoder. At the 12-bit
##      ceiling (next_code == 4097) emit CLEAR and re-seed instead.
static func _lzw(indices: PackedByteArray) -> PackedByteArray:
	var min_code_size := 8
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1
	var code_size := min_code_size + 1
	var next_code := end_code + 1
	var dict := {}
	var codes := PackedInt32Array()
	var widths := PackedByteArray()
	codes.append(clear_code)
	widths.append(code_size)
	if indices.is_empty():
		codes.append(end_code)
		widths.append(code_size)
		return _pack_bits(codes, widths)
	var prev := indices[0]
	var i := 1
	while i < indices.size():
		var k := indices[i]
		var key := (prev << 8) | k
		if dict.has(key):
			prev = dict[key]
		else:
			codes.append(prev)
			widths.append(code_size)
			dict[key] = next_code
			next_code += 1
			if next_code == (1 << code_size) + 1:
				if code_size < 12:
					code_size += 1
				else:
					codes.append(clear_code)
					widths.append(code_size)
					dict.clear()
					next_code = end_code + 1
					code_size = min_code_size + 1
			prev = k
		i += 1
	codes.append(prev)
	widths.append(code_size)
	codes.append(end_code)
	widths.append(code_size)
	return _pack_bits(codes, widths)


static func _pack_bits(codes: PackedInt32Array, widths: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var buf := 0
	var cnt := 0
	for i in range(codes.size()):
		buf |= codes[i] << cnt
		cnt += widths[i]
		while cnt >= 8:
			out.append(buf & 0xFF)
			buf >>= 8
			cnt -= 8
	if cnt > 0:
		out.append(buf & 0xFF)
	return out
