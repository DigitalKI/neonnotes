class_name VaultSearch
extends RefCounted
## Shared search semantics for the vault: a query is `#tags` plus keywords.
## Tags filter the in-memory tag index (AND-ed, case-insensitive); keywords of
## at least MIN_KEYWORD characters search note titles first and bodies second.
##
## Two surfaces read the same rules — the sidebar tree and the Move page's
## destination tree — so they live here instead of in either component.
## The instance half holds one parsed query; the static half is the matching
## logic (no autoload access: callers pass the note list and tag index, so it is
## unit-testable and safe to run on a worker with plain names/titles/text).

## Shorter keyword fragments are treated as "not searching yet": they would
## match nearly every note and cost a full-vault read for nothing.
const MIN_KEYWORD := 3

## The stripped query as typed.
var query := ""
## Lower-cased tags parsed out of the query; a note must carry all of them.
var tags: Array[String] = []
## Everything that is not a #tag, joined with single spaces.
var text := ""


## Parse `value` into tags + keywords. Mirrors the sidebar's field semantics.
func set_query(value: String) -> void:
	query = value.strip_edges()
	tags = []
	var words: Array[String] = []
	for token in query.split(" ", false):
		if token.begins_with("#"):
			var t := token.substr(1).strip_edges().to_lower()
			if t != "" and not tags.has(t):
				tags.append(t)
		else:
			words.append(token)
	text = " ".join(words)


## A query is active with any #tag, or a keyword of at least MIN_KEYWORD chars.
## Tag-only queries never touch the disk: they filter the in-memory index.
func is_active() -> bool:
	return not tags.is_empty() or text.length() >= MIN_KEYWORD


## True when `rel` carries every tag in `wanted` according to `tag_index`
## (rel -> Array[String]). Case-insensitive; the index keeps the original casing.
static func matches_tags(rel: String, wanted: Array, tag_index: Dictionary) -> bool:
	if wanted.is_empty():
		return true
	var note_tags: Array = tag_index.get(rel, [])
	for want in wanted:
		var found := false
		for t in note_tags:
			if String(t).to_lower() == want:
				found = true
				break
		if not found:
			return false
	return true


## Notes in `notes` carrying every tag in `wanted`, in input order.
static func tag_candidates(notes: Array, wanted: Array, tag_index: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for n in notes:
		if matches_tags(str(n), wanted, tag_index):
			out.append(str(n))
	return out


## Keyword hits over `names`, title-first: a note whose title already contains
## every word is a hit with no disk read; the rest are matched against
## (title + body). Runs on a worker: it only reads files and plain data, and
## calls `cancelled` between notes so a newer query can stop it early.
static func keyword_hits(names: Array, titles: Dictionary, vault_path: String,
		query: String, cancelled: Callable) -> Array:
	var title_hits: Array = []
	var content_hits: Array = []
	# Case-insensitive on both sides; the raw query keeps the typed casing.
	var words := query.to_lower().split(" ", false)
	for name in names:
		if _is_cancelled(cancelled):
			return []
		var title: String = String(titles.get(name, ""))
		var title_lower := title.to_lower()
		var title_matches := true
		for word in words:
			if not title_lower.contains(word):
				title_matches = false
				break
		if title_matches:
			title_hits.append(name)
			continue
		var text := TextIO.read_text(vault_path.path_join(str(name)))
		if _is_cancelled(cancelled):
			return []
		var haystack := (title + "\n" + text).to_lower()
		var matches_all := true
		for word in words:
			if not haystack.contains(word):
				matches_all = false
				break
		if matches_all:
			content_hits.append(name)
	return title_hits + content_hits


static func _is_cancelled(cancelled: Callable) -> bool:
	return cancelled.is_valid() and bool(cancelled.call())
