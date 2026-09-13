class_name GlitchFx extends RichTextEffect

var bbcode := "glitch"
var _time := 0.0

func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	_time = Time.get_ticks_msec() / 1000.0
	var phase := fmod(_time, 2.4)
	var burst := sin(phase * 9.0) * (0.5 + 0.5 * sin(phase * 3.1))
	# float offsets: visible at any DPI/canvas scale
	char_fx.offset.x += burst * 8.0
	char_fx.offset.y += sin(phase * 13.0 + char_fx.relative_index) * 1.5
	# RGB-split style flicker: periodic color glitch bursts
	if fmod(_time * 17.0 + char_fx.relative_index, 31.0) < 2.5:
		char_fx.color = Color(1.0, 0.25, 0.85, char_fx.color.a)
		char_fx.offset.x += 4.0
	# occasional character dropout flash
	if fmod(_time * 9.0 + char_fx.relative_index * 0.37, 17.0) < 0.4:
		char_fx.color = Color(0.2, 1.0, 0.9, char_fx.color.a)
	return true
