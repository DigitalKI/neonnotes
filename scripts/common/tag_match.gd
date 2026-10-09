class_name TagMatch
extends RefCounted
## Pure tag-matching helpers shared by TagSuggest and unit tests.
## No autoload/tree dependency, so it also compiles under `godot --script`.
##
## The Levenshtein/ranking core is general text similarity and now lives in
## TextMatch (shared with wikilink resolution); this class keeps the tag-facing
## API stable.

## Preloaded (not the global class_name) so the script still resolves when run
## directly via `godot --script tests/unit_tests.gd`, where class_name globals
## are not registered.
const TextMatchScript := preload("res://scripts/common/text_match.gd")
const NEAR_MATCH_LIMIT := 2

## Rank a tag against a typed prefix:
##   0 = exact or prefix, 1 = substring, 2+ = near-match (distance-encoded),
##  -1 = no match. Near-matches catch stem/typo duplicates such as coding/code
##  and jw/j-w, which prefix and substring matching alone would miss.
static func score(tag_name: String, prefix: String) -> int:
	return TextMatchScript.score(tag_name, prefix, NEAR_MATCH_LIMIT)

## Levenshtein distance on short strings (tags), capped for safety.
static func edit_distance(a: String, b: String) -> int:
	return TextMatchScript.edit_distance(a, b)
