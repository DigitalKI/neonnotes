class_name FlickerFx extends RichTextEffect

var bbcode := "flicker"

## Full loop period of the flicker effect in seconds. The alpha-dip repeats on
## `fmod(t * 1.37, 5.8) < 0.16` → 5.8/1.37 ≈ 4.23s (the longest repeating event;
## the sine trough at 2.7 rad/s has a ~2.33s period). Used by the exporter so an
## exported GIF runs a complete flicker cycle instead of a too-short fragment.
const ANIMATION_DURATION := 5.8 / 1.37

func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var t := Time.get_ticks_msec() / 1000.0
	var wave := sin(t * 2.7 + char_fx.relative_index * 0.17)
	var dip := 1.0
	if fmod(t * 1.37 + char_fx.relative_index * 0.11, 5.8) < 0.16: dip = 0.18
	elif wave < -0.94: dip = 0.62
	char_fx.color.a *= dip
	return true
