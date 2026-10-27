class_name AreaLayout
extends RefCounted
## Pure, deterministic area/island layout for Area View (ADR-0013 Phase 5).
##
## Groups notes into connected components of a similarity graph (union-find),
## then packs each island onto a stable grid inside `viewport`. No physics and
## no randomness: the same input yields the same positions, and adding or
## removing a note only moves the island it belongs to, so edits stay visually
## stable. Dependency-free and unit-testable under `godot --script`.
##
## Input: `neighbours` maps every note to lay out -> its top-k neighbours as
## [{note, score}] (the `TfidfIndex.top_neighbors` shape). Isolated notes map
## to an empty array and still get a position (a lone island).

static func layout(neighbours: Dictionary, viewport: Rect2) -> Dictionary:
	var parent := {}
	for n in neighbours.keys():
		parent[n] = n
	for src in neighbours.keys():
		for e in neighbours[src]:
			var dst := String(e.get("note", ""))
			if dst != "" and parent.has(dst):
				_union(parent, String(src), dst)

	# Group by root, sorted for determinism.
	var islands := {}
	for n in parent.keys():
		var root := _find(parent, String(n))
		if not islands.has(root):
			islands[root] = []
		islands[root].append(String(n))
	var island_list: Array = []
	for root in islands.keys():
		var members: Array = islands[root]
		members.sort()
		island_list.append(members)
	island_list.sort_custom(func(a, b):
		if a.size() == b.size():
			return String(a[0]) < String(b[0])
		return a.size() > b.size())

	# Pack islands on a square-ish grid so unrelated subjects stay apart.
	var cols := maxi(1, ceili(sqrt(float(island_list.size()))))
	var cell_w := viewport.size.x / float(cols)
	var rows := maxi(1, ceili(float(island_list.size()) / float(cols)))
	var cell_h := viewport.size.y / float(rows)

	var out := {}
	for i in island_list.size():
		var members: Array = island_list[i]
		var row := i / cols
		var col := i % cols
		var center := viewport.position + Vector2(
			(float(col) + 0.5) * cell_w, (float(row) + 0.5) * cell_h)
		if members.size() == 1:
			out[members[0]] = center
			continue
		var radius := minf(cell_w, cell_h) * 0.3
		for j in members.size():
			var ang := TAU * float(j) / float(members.size())
			out[members[j]] = center + Vector2(cos(ang), sin(ang)) * radius
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
