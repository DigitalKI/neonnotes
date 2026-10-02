// CRT overlay: scanlines + aperture-grille mask, luminance-preserving.
//
// CREDIT — Adapted from the Godot Shaders community shader
//   "CRT with Luminance Preservation"
//   https://godotshaders.com/shader/crt-with-luminance-preservation/
//
// This is a pure MULTIPLICATIVE overlay (render_mode blend_mul): it darkens the
// already-drawn frame with a scanline/grille pattern instead of reading the
// frame back. The previous version sampled SCREEN_TEXTURE, which in the
// gl_compatibility renderer forces a full-framebuffer backbuffer copy every
// frame plus a fullscreen fragment pass — that single line was effectively the
// app's entire idle GPU cost (a static 2D UI otherwise idles near 0%). Because
// blend_mul needs no screen read, the same look now costs almost nothing.
//
// The screen-sampling version also did a barrel curve + sub-pixel wobble; both
// had to displace the sampled screen, so they are gone here. They were tuned
// near-invisible on purpose (curve 0.011, wobble 0.155) and the scanline/grille
// pattern — the visible part of the effect — is produced identically below.
//
// LDR note: the grille brightens one subpixel (1 + mask_strength) and darkens
// the other two (1 - mask_strength). With blend_mul the blend factor is clamped
// to [0, 1] on an 8-bit target, so the "brighten" caps at 1.0 — the dark
// subpixels are unchanged, so the grille looks the same, just ~9% darker overall
// than the old screen-sampling version (which could brighten in-shader).
shader_type canvas_item;
render_mode blend_mul;

uniform float scanline_strength : hint_range(0.0, 1.0) = 0.12;
uniform float mask_strength : hint_range(0.0, 1.0) = 0.10;
uniform int mask_type : hint_range(0, 2) = 2;

void fragment() {
	vec3 col = vec3(1.0);
	// Scanlines (2px pitch, luminance-preserving) in device pixels.
	float scan = sin(FRAGCOORD.y * 3.14159);
	col *= 1.0 - scanline_strength * 0.5 * (1.0 - scan * scan);

	// Phosphor mask (3px RGB aperture grille).
	if (mask_type == 2) {
		float px = mod(FRAGCOORD.x, 3.0);
		if (px < 1.0) col *= vec3(1.0 + mask_strength, 1.0 - mask_strength, 1.0 - mask_strength);
		else if (px < 2.0) col *= vec3(1.0 - mask_strength, 1.0 + mask_strength, 1.0 - mask_strength);
		else col *= vec3(1.0 - mask_strength, 1.0 - mask_strength, 1.0 + mask_strength);
	} else if (mask_type == 1) {
		float px = mod(FRAGCOORD.x, 2.0);
		col *= 1.0 - mask_strength * 0.5 * px;
	}
	COLOR = vec4(col, 1.0);
}
