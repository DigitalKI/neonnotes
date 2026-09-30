class_name TagMatch
extends RefCounted
## Pure tag-matching helpers shared by TagSuggest and unit tests.
## No autoload/tree dependency, so it also compiles under `godot --script`.

const NEAR_MATCH_LIMIT := 2

## Rank a tag against a typed prefix:
##   0 = exact or prefix, 1 = substring, 2+ = near-match (distance-encoded),
##  -1 = no match. Near-matches catch stem/typo duplicates such as coding/code
##  and jw/j-w, which prefix and substring matching alone would miss.
static func score(tag_name: String, prefix: String) -> int:
	if prefix == "":
		return 0
	if tag_name.begins_with(prefix):
		return 0
	if tag_name.contains(prefix):
		return 1
	if prefix.length() >= 2:
		var d := edit_distance(tag_name, prefix)
		if d <= NEAR_MATCH_LIMIT or d * 2 <= maxi(tag_name.length(), prefix.length()):
			return 2 + d
	return -1

## Levenshtein distance on short strings (tags), capped for safety.
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
