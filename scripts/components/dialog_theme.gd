class_name DialogTheme
extends RefCounted
## Palette theming for the remaining real Window dialog: the OS-style image
## FileDialog (the only popup left — every other surface is a page inside
## %Content). Applies the same panel StyleBoxFlat, mono font and accent colors
## the shell uses. Call apply() when the dialog is created and again on
## GameManager.palette_changed.
static func apply(dialog: Window) -> void:
	if dialog == null:
		return
	var accent := GameManager.color("accent")
	var accent2 := GameManager.color("accent2")
	var panel := GameManager.color("panel")
	var text := GameManager.color("text")

	var bg := StyleBoxFlat.new()
	bg.bg_color = panel
	bg.border_color = accent
	bg.set_border_width_all(2)
	bg.corner_radius_top_left = 8
	bg.corner_radius_top_right = 8
	bg.corner_radius_bottom_left = 8
	bg.corner_radius_bottom_right = 8
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 10
	bg.content_margin_bottom = 10
	dialog.add_theme_stylebox_override("panel", bg)
	dialog.add_theme_color_override("font_color", text)
	dialog.add_theme_color_override("font_hover_color", accent2)
	dialog.add_theme_color_override("font_selected_color", text)
	dialog.add_theme_color_override("accent_color", accent)
	# Follow the user's font family/size preference (real OS Window dialogs do
	# not inherit the window-root theme, so this is set explicitly).
	dialog.add_theme_font_override("font", GameManager.font())
	dialog.add_theme_font_size_override("font_size", GameManager.font_size)
