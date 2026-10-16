shader_type canvas_item;

// Graph node markers, one MultiMesh quad per node.
//
// Why: the old per-node `draw_circle`/`draw_polyline`/`draw_arc` pass emitted
// ~2 draw calls per node, so a thousands-of-nodes map cost thousands of draw
// calls every frame — fatal on mobile GPUs, which are draw-call bound. Every
// marker is now one instance of a MultiMesh, so a whole marker class is one
// draw call regardless of node count. The quad is carved into the marker shape
// in the fragment shader.
//
// `canvas_item` shaders expose no per-instance custom data (INSTANCE_CUSTOM is
// spatial-only) — only the per-instance COLOR. So the shape parameters are
// constant per MultiMesh and come in as uniforms; GraphView uses three
// instances of this material: filled leaf discs, folder diamond outlines, and
// the collapsed-folder ring.
//
// Per-instance input: COLOR (the node tint; alpha carries focus dimming).

uniform int mode : hint_range(0, 2) = 0;  // 0 = disc, 1 = diamond outline, 2 = ring
uniform float radius_frac = 0.6;          // marker radius / quad half-size
uniform float halo_alpha = 0.08;          // 0 disables the halo
uniform float ring_t = 0.0;               // ring radius in marker-radius units

void fragment() {
	// Normalised quad position: 0 at the centre, 1 at an edge midpoint.
	vec2 dn = (UV - vec2(0.5)) * 2.0;
	// Distance in units of the marker radius (1.0 sits on the marker outline).
	float t = (mode == 1 ? abs(dn.x) + abs(dn.y) : length(dn))
		/ max(radius_frac, 0.001);
	float aa = max(fwidth(t), 0.002);

	float core = 0.0;
	if (mode == 1) {
		// Folder: an outlined diamond, hollow like the old polyline.
		core = 1.0 - smoothstep(aa, aa * 2.0, abs(t - 1.0));
	} else if (mode == 0) {
		// Leaf: a filled disc.
		core = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, t);
	}

	float ring = 0.0;
	if (mode == 2) {
		float rw = max(aa, 0.02);
		ring = 1.0 - smoothstep(rw, rw * 2.0, abs(t - ring_t));
	}

	// Soft halo fading from the marker outline out to the quad edge (the quad is
	// sized to radius + a chosen halo width, so the falloff stops there).
	float halo = 0.0;
	if (halo_alpha > 0.001) {
		halo = (1.0 - smoothstep(1.0, 1.0 / max(radius_frac, 0.05), t)) * halo_alpha;
	}

	float a = COLOR.a * (core + ring * 0.9 + halo);
	if (a <= 0.004) {
		discard;
	}
	COLOR = vec4(COLOR.rgb, a);
}
