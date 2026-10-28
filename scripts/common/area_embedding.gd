class_name AreaEmbedding
extends RefCounted
## Continuous, deterministic force-directed layout for Area View (ADR-0016).
##
## Input: a k-NN similarity graph in the `TfidfIndex.knn_graph()` shape —
## `{note: [{note, score}]}`. Output: `{note: Vector2}` in a fixed square map
## frame (`MAP_SPAN`); the view's camera fits it, the layout never knows the
## viewport. Pure and dependency-free like `AreaLayout`, so it unit-tests
## under `godot --script`.
##
## The shape of the map, in order:
##   1. Connected components of the similarity graph are anchored on a
##      deterministic grid, largest first (ties by name) — unrelated subjects
##      keep separate regions instead of drifting onto each other.
##   2. Members start on a golden-angle spiral around their component's
##      anchor, sized to the component, so the relaxation begins spread.
##   3. A Fruchterman–Reingold relaxation runs a fixed iteration count under a
##      linear temperature schedule: similarity edges attract (scaled by the
##      cosine weight — the stronger the overlap, the tighter the pair) while
##      nearby nodes repel within a radius through a spatial hash. Distant
##      nodes do not interact at all, so one region's edit cannot wander
##      another region's placement.
##
## No randomness anywhere, and every pass walks sorted, stable orders, so the
## same input yields bit-identical positions (the `AreaLayout` contract).
## Editing a note changes only its component's edges — its own region moves,
## and at most the grid anchors; the rest of the map stays put.

const MAP_SPAN := 1000.0        # square map frame; `_fit_to_view()` frames it
const ITERATIONS := 150        # fixed: determinism over adaptive stopping
const IDEAL_C := 0.9           # FR ideal distance: k = C·sqrt(span²/N)
const REPEL_K := 3.0          # repulsion reach as a multiple of the ideal
const WEIGHT_BASE := 0.2      # attraction gain: base + WEIGHT_GAIN·weight
const WEIGHT_GAIN := 1.3
const TEMP_FRAC := 0.12        # start temperature as a fraction of the span
const FIT_PAD := 60.0          # padding kept when fitting the frame
const GOLDEN_ANGLE := 2.399963229728653  # even spiral, no RNG

static func layout(graph: Dictionary, iterations := ITERATIONS) -> Dictionary:
	var keys: Array[String] = []
	for k in graph.keys():
		keys.append(String(k))
	keys.sort()
	var out := {}
	if keys.is_empty():
		return out
	var n := keys.size()
	var ideal := IDEAL_C * sqrt(MAP_SPAN * MAP_SPAN / float(n))
	var radius := REPEL_K * ideal

	# 1. Undirected edges — the max of the two directed scores — plus the
	#    connected components (union-find, same as the island layout).
	var parent := {}
	var weight := {}
	for k in keys:
		parent[k] = k
	for k in keys:
		for e in graph[k]:
			var b := String(e.get("note", ""))
			var w := float(e.get("score", 0.0))
			if b == "" or b == k or not parent.has(b) or w <= 0.0:
				continue
			_union(parent, k, b)
			var a := k
			if a > b:
				var t := a
				a = b
				b = t
			var ek := a + "|" + b
			if w > float(weight.get(ek, 0.0)):
				weight[ek] = w
	var by_root := {}
	for k in keys:
		var root := _find(parent, k)
		if not by_root.has(root):
			by_root[root] = []
		by_root[root].append(k)
	var comps: Array = by_root.values()
	comps.sort_custom(func(a, b):
		if a.size() == b.size():
			return String(a[0]) < String(b[0])
		return a.size() > b.size())

	# 2. Anchor each component on the grid, largest first, and spread its
	#    members on a golden-angle spiral sized to the component.
	var cols := maxi(1, ceili(sqrt(float(comps.size()))))
	var rows := maxi(1, ceili(float(comps.size()) / float(cols)))
	var cell_w := MAP_SPAN / float(cols)
	var cell_h := MAP_SPAN / float(rows)
	var pos := {}
	for ci in comps.size():
		var members: Array = comps[ci]
		var anchor := Vector2((float(ci % cols) + 0.5) * cell_w,
			(float(ci / cols) + 0.5) * cell_h)
		if members.size() == 1:
			pos[members[0]] = anchor
			continue
		var r_init := minf(minf(cell_w, cell_h) * 0.45,
			ideal * sqrt(float(members.size())))
		for j in members.size():
			var ang := float(j) * GOLDEN_ANGLE
			var rr := r_init * sqrt((float(j) + 1.0) / float(members.size()))
			pos[members[j]] = anchor + Vector2(cos(ang), sin(ang)) * rr

	# Edge list in sorted key order for a deterministic attraction walk.
	var edge_list: Array = []
	var ekeys := weight.keys()
	ekeys.sort()
	for ek in ekeys:
		var parts := String(ek).split("|", false, 1)
		edge_list.append([String(parts[0]), String(parts[1]), float(weight[ek])])

	# 3. FR relaxation: attraction along edges, repulsion within `radius`
	#    through a spatial hash; displacements clamp to a cooling temperature.
	var t0 := TEMP_FRAC * MAP_SPAN
	var cell := maxf(radius * 0.5, 1.0)
	for it in iterations:
		var temp := t0 * (1.0 - float(it) / float(iterations))
		var disp := {}
		for k in keys:
			disp[k] = Vector2.ZERO
		for e in edge_list:
			var a: String = e[0]
			var b: String = e[1]
			var dvec: Vector2 = Vector2(pos[b]) - Vector2(pos[a])
			var d := dvec.length()
			if d <= 0.0001:
				continue
			var gain := WEIGHT_BASE + WEIGHT_GAIN * float(e[2])
			var step := dvec / d * (gain * d * d / ideal) * 0.5
			disp[a] = Vector2(disp[a]) + step
			disp[b] = Vector2(disp[b]) - step
		var grid := {}
		for k in keys:
			var idx := Vector2i(floori(float(pos[k].x) / cell),
				floori(float(pos[k].y) / cell))
			if not grid.has(idx):
				grid[idx] = []
			grid[idx].append(k)
		for k in keys:
			var pk: Vector2 = pos[k]
			var ck := Vector2i(floori(pk.x / cell), floori(pk.y / cell))
			for gx in range(ck.x - 2, ck.x + 3):
				for gy in range(ck.y - 2, ck.y + 3):
					for o in grid.get(Vector2i(gx, gy), []):
						if String(o) <= k:
							continue  # every unordered pair exactly once
						var dv: Vector2 = pk - Vector2(pos[String(o)])
						var dd := dv.length()
						if dd >= radius or dd <= 0.0001:
							continue
						var step := dv / dd * (ideal * ideal / dd) * 0.5
						disp[k] = Vector2(disp[k]) + step
						disp[String(o)] = Vector2(disp[String(o)]) - step
		for k in keys:
			var v: Vector2 = disp[k]
			var l := v.length()
			if l > temp and l > 0.0:
				v = v / l * temp
			pos[k] = Vector2(pos[k]) + v

	# 4. Fit the relaxed cloud into the map frame: uniform scale, centred.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in keys:
		lo = lo.min(pos[k])
		hi = hi.max(pos[k])
	var span := maxf((hi - lo).x, (hi - lo).y)
	if span <= 0.0001:
		for k in keys:
			out[k] = Vector2(MAP_SPAN, MAP_SPAN) * 0.5
		return out
	var scale := (MAP_SPAN - FIT_PAD * 2.0) / span
	var center := (lo + hi) * 0.5
	for k in keys:
		out[k] = (Vector2(pos[k]) - center) * scale \
			+ Vector2(MAP_SPAN, MAP_SPAN) * 0.5
	return out

static func _find(parent: Dictionary, x: String) -> String:
	var root := x
	while String(parent.get(root, root)) != root:
		root = String(parent[root])
	var node := x
	while node != root:
		var nxt := String(parent[node])
		parent[node] = root
		node = nxt
	return root

static func _union(parent: Dictionary, a: String, b: String) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra