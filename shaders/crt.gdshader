shader_type canvas_item;
// Subtle CRT overlay: scanlines + aperture-grille mask, luminance-preserving.
// Defaults tuned flat so reading isn't distorted.

uniform float curve : hint_range(0.0, 1.0) = 0.0;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.12;
uniform float mask_strength : hint_range(0.0, 1.0) = 0.10;
uniform float wobble_strength : hint_range(0.0, 10.0) = 0.0;
uniform int mask_type : hint_range(0, 2) = 2;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear;
void fragment() {
	vec2 uv = SCREEN_UV;
	// barrel curvature
	if (curve > 0.0) {
		uv = uv * 2.0 - 1.0;
		uv *= 1.0 + curve * 0.08 * vec2(dot(uv, uv), dot(uv, uv));
		uv = uv * 0.5 + 0.5;
	}
	// gentle horizontal wobble
	uv.x += sin(uv.y * 700.0 + TIME * 2.0) * 0.0004 * wobble_strength;

	vec3 col = textureLod(SCREEN_TEXTURE, uv, 0.0).rgb;

	// scanlines (2px pitch, luminance-preserving)
	float scan = sin(uv.y / SCREEN_PIXEL_SIZE.y * 3.14159);
	col *= 1.0 - scanline_strength * 0.5 * (1.0 - scan * scan);

	// phosphor mask
	if (mask_type == 2) {
		float px = mod(FRAGCOORD.x, 3.0);
		vec3 mask = vec3(1.0);
		if (px < 1.0) mask = vec3(1.0 + mask_strength, 1.0 - mask_strength, 1.0 - mask_strength);
		else if (px < 2.0) mask = vec3(1.0 - mask_strength, 1.0 + mask_strength, 1.0 - mask_strength);
		else mask = vec3(1.0 - mask_strength, 1.0 - mask_strength, 1.0 + mask_strength);
		col *= mask;
	} else if (mask_type == 1) {
		float px = mod(FRAGCOORD.x, 2.0);
		col *= 1.0 - mask_strength * 0.5 * px;
	}
	COLOR = vec4(col, 1.0);
}
