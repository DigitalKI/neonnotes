class_name TextMatch
extends RefCounted
## Pure, dependency-free text-similarity helpers shared by tag autocomplete and
## wikilink resolution. No autoload/tree access, so it also compiles under
## `godot --script` and is directly unit-testable (like TagMatch/MarkdownParser).
##
## Ranking is: exact/prefix (0) → substring (1) → near-match (2 + distance).
## Near-matches catch stem/typo variants ("coding"/"code", "jw"/"j-w",
## "Ntoes"/"Notes") that prefix and substring alone would miss.

const NEAR_MATCH_LIMIT := 2

## Rank a candidate against a typed query:
##   0 = exact or prefix, 1 = substring, 2+ = near-match (distance-encoded),
##  -1 = no match. `near_limit` caps the Levenshtein distance accepted for the
##  near-match tier (default 2, matching TagMatch).
static func score(candidate: String, query: String, near_limit := NEAR_MATCH_LIMIT) -> int:
	if query == "":
		return 0
	if candidate.begins_with(query):
		return 0
	if candidate.contains(query):
		return 1
	if query.length() >= 2:
		var d := edit_distance(candidate, query)
		if d <= near_limit or d * 2 <= maxi(candidate.length(), query.length()):
			return 2 + d
	return -1

## Levenshtein distance on short strings (tags, note names), capped for safety.
static func edit_distance(a: String, b: String) -> int:
	var n := mini(a.length(), 64)
	var m := mini(b.length(), 64)
	if n == 0:
		return m
	if m == 0:
		return n
	var prev: Array[int] = []
	for j in m + 1:
		prev.append(j)
	for i in range(1, n + 1):
		var cur: Array[int] = [i]
		for j in range(1, m + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur.append(mini(mini(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost))
		prev = cur
	return prev[m]

## Rank `candidates` (entries with at least a "value"; optional "keys" list of
## strings to match against, defaulting to "value") against `query`. Returns the
## best `limit` entries (best first) as copies carrying "score" and "distance".
##
## `max_distance` is a *hard* Levenshtein cap on the near-match tier (unlike
## `score()`, whose tag-style "half the length" rule admits larger distances),
## so a UI can widen/narrow it live. Tiering: exact 0, prefix 1, substring 2,
## near 3 + distance.
static func rank(query: String, candidates: Array, max_distance := NEAR_MATCH_LIMIT, limit := 8) -> Array:
	var q := query.strip_edges().to_lower()
	var scored: Array = []
	for c in candidates:
		if not (c is Dictionary):
			continue
		var keys: Array = c.get("keys", [])
		if keys.is_empty():
			keys = [c.get("value", "")]
		var best := -1
		var best_d := 1 << 30
		for k in keys:
			var kl := String(k).strip_edges().to_lower()
			if kl == "":
				continue
			var s := -1
			var d := 1 << 30
			if q != "" and kl == q:
				s = 0
				d = 0
			elif q != "" and kl.begins_with(q):
				s = 1
				d = edit_distance(kl, q)
			elif q != "" and kl.contains(q):
				s = 2
				d = edit_distance(kl, q)
			elif q.length() >= 2:
				var ed := edit_distance(kl, q)
				if ed <= max_distance:
					s = 3 + ed
					d = ed
			if s < 0:
				continue
			if best < 0 or s < best or (s == best and d < best_d):
				best = s
				best_d = d
		if best < 0:
			continue
		var entry: Dictionary = c.duplicate()
		entry["score"] = best
		entry["distance"] = best_d
		scored.append(entry)
	scored.sort_custom(func(a, b) -> bool:
		if a["score"] != b["score"]:
			return a["score"] < b["score"]
		if a["distance"] != b["distance"]:
			return a["distance"] < b["distance"]
		return String(a.get("label", a.get("value", ""))) < String(b.get("label", b.get("value", ""))))
	if limit > 0 and scored.size() > limit:
		scored.resize(limit)
	return scored
