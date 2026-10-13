class_name GraphDigest extends RefCounted
## Cheap, UI-independent summary of a single note ("what is inside this node").
##
## `summarize()` is a pure function over note text: it never touches the tree,
## so it is safe to run on a worker thread (see `GraphDigestStore`). The card
## view-model builders at the bottom do read the shared `GameManager` indexes,
## so those run on the main thread only.

## Excerpt budget in characters. The card clamps its own display too; this is
## the stored size so the view-model stays small.
const EXCERPT_MAX := 200
const EXCERPT_LINES := 2

## How much of the note the focus card renders as a live preview, in source
## lines. Easy-to-tune knob: the card hands these lines to the same
## `MarkdownParser` + `PreviewBuilder` pipeline the note view uses, so the
## preview looks identical — only shorter. Raise it for more context, lower it
## to keep the graph card light on very large notes.
const PREVIEW_LINES := 50

const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

static var _re_wiki: RegEx
static var _re_md_link: RegEx
static var _re_stamp: RegEx

# ------------------------------------------------------------ pure extraction

## Summarize note source (front matter included). Every field is best-effort:
## a missing value is "" or 0, never an error.
static func summarize(source: String) -> Dictionary:
	var body := NoteMetadata.body(source)
	var tag_list: Array[String] = []
	for raw in NoteMetadata.field(source, "tags", "").split(",", false):
		var tag := String(raw).strip_edges().trim_prefix("#")
		if tag != "" and not tag_list.has(tag):
			tag_list.append(tag)
	var heading := ""
	for line in body.split("\n", true):
		var s := String(line).strip_edges()
		if s.begins_with("#"):
			heading = s.lstrip("#").strip_edges()
			break
	return {
		"title": NoteMetadata.field(source, "title", ""),
		"tags": tag_list,
		"excerpt": excerpt_of(body),
		"preview": preview_of(body),
		"heading": heading,
		"words": word_count(body),
		"checklist_open": count_open_checklist(body),
		"images": count_occurrences(body, "!["),
		"links_out": GameManager.extract_wiki_links(body).size(),
		"created": NoteMetadata.field(source, "created", ""),
		"updated": NoteMetadata.field(source, "updated", ""),
	}

## First non-blank, non-heading body lines, stripped of Markdown decoration.
static func excerpt_of(body: String) -> String:
	var out := ""
	var taken := 0
	for line in body.split("\n", true):
		var text := strip_markdown(line)
		if text == "":
			continue
		if out != "":
			out += " "
		out += text
		taken += 1
		if taken >= EXCERPT_LINES or out.length() >= EXCERPT_MAX:
			break
	if out.length() > EXCERPT_MAX:
		var cut := out.substr(0, EXCERPT_MAX)
		var space := cut.rfind(" ")
		if space > EXCERPT_MAX / 2:
			cut = cut.substr(0, space)
		out = cut.rstrip(" ,.;:") + "…"
	return out

## The note body's first PREVIEW_LINES source lines, kept verbatim (front-matter
## already stripped) so the focus card can render it through the real preview
## pipeline. Truncation is per-line; a block that runs past the cut is simply
## cut, which the parser tolerates. Pure and cheap, so it stays worker-safe.
static func preview_of(body: String) -> String:
	var all := body.split("\n", true)
	if all.size() <= PREVIEW_LINES:
		return body
	return "\n".join(all.slice(0, PREVIEW_LINES))

## One body line as readable prose: drop heading/list/quote/checkbox markers,
## flatten `[[wiki|label]]` and `[text](url)` to their label, drop emphasis.
static func strip_markdown(line: String) -> String:
	var s := String(line).strip_edges()
	if s.begins_with("#"):
		s = s.lstrip("#").strip_edges()
	if s.begins_with(">"):
		s = s.lstrip(">").strip_edges()
	if s.begins_with("- ") or s.begins_with("* ") or s.begins_with("+ "):
		s = s.substr(2).strip_edges()
	if s.begins_with("[ ]") or s.begins_with("[x]") or s.begins_with("[X]"):
		s = s.substr(3).strip_edges()
	if s.begins_with("```") or s.begins_with("~~~"):
		return ""
	if _wiki_regex().search(s) != null:
		s = _wiki_labeled(s)
	if _md_link_regex().search(s) != null:
		s = _md_link_regex().sub(s, "$1")
	for token in ["**", "__", "`", "~~", "*"]:
		s = s.replace(token, "")
	return s.strip_edges()

## `[[target|label]]` → label, `[[target]]` → target.
static func _wiki_labeled(s: String) -> String:
	var re := _wiki_regex()
	var out := ""
	var rest := s
	var m := re.search(rest)
	while m != null:
		out += rest.substr(0, m.get_start())
		var label := m.get_string(2)
		out += label if label != "" else m.get_string(1)
		rest = rest.substr(m.get_end())
		m = re.search(rest)
	return out + rest

static func word_count(body: String) -> int:
	return body.split(" ", false).size()

## Open checklist items only; a checked box is not "work left".
static func count_open_checklist(body: String) -> int:
	return count_occurrences(body, "[ ]")

static func count_occurrences(text: String, needle: String) -> int:
	var n := 0
	var at := text.find(needle)
	while at >= 0:
		n += 1
		at = text.find(needle, at + needle.length())
	return n

static func _wiki_regex() -> RegEx:
	if _re_wiki == null:
		_re_wiki = RegEx.new()
		_re_wiki.compile("\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]")
	return _re_wiki

static func _md_link_regex() -> RegEx:
	if _re_md_link == null:
		_re_md_link = RegEx.new()
		_re_md_link.compile("\\[([^\\]]+)\\]\\([^)]*\\)")
	return _re_md_link

# ------------------------------------------------------------------- dates

## "2026-10-11T18:03:00" (UTC, as GameManager writes it) → "Oct 11, 2026".
static func human_date(raw: String) -> String:
	var d := datetime_dict(raw)
	if d.is_empty():
		return ""
	return "%s %d, %d" % [MONTHS[int(d["month"]) - 1], int(d["day"]), int(d["year"])]

## Compact age: "today", "yesterday", "3d ago", "2mo ago", "1y ago".
static func relative_age(raw: String) -> String:
	var d := datetime_dict(raw)
	if d.is_empty():
		return ""
	var then := Time.get_unix_time_from_datetime_dict(d)
	var now := Time.get_unix_time_from_system()
	# Whole UTC days between the two stamps — "3d ago" must not be off by one
	# just because the note was edited late in the day.
	var days := maxi(0, int(now / 86400.0) - int(then / 86400.0))
	if days < 1:
		return "today"
	if days == 1:
		return "yesterday"
	if days < 30:
		return "%dd ago" % days
	if days < 365:
		return "%dmo ago" % maxi(1, days / 30)
	return "%dy ago" % maxi(1, days / 365)

## Parse the stored UTC stamp; empty dict when the value is missing/garbage.
## The shape is checked first: Time.get_datetime_dict_from_datetime_string()
## prints an engine error for anything it cannot parse, which is noise for the
## blank/legacy front matter this helper is expected to meet.
static func datetime_dict(raw: String) -> Dictionary:
	var text := String(raw).strip_edges().replace(" ", "T")
	if _re_stamp == null:
		_re_stamp = RegEx.new()
		_re_stamp.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}")
	if _re_stamp.search(text) == null:
		return {}
	var d := Time.get_datetime_dict_from_datetime_string(text, true)
	if d.is_empty() or int(d.get("year", 0)) <= 0:
		return {}
	return d

# ------------------------------------------- card view-models (main thread)

## Display model for a single note. `digest` may be empty while the worker is
## still reading the file: the index-backed fields (title, tags, links) are
## always available, so the card renders immediately and fills in later.
static func note_card(rel: String, digest: Dictionary, resolve_maps: Array = []) -> Dictionary:
	var maps := resolve_maps if not resolve_maps.is_empty() else WikiLinks.resolve_maps()
	var outbound: Array[Dictionary] = []
	for target in GameManager.links.get(rel, []):
		var name := String(target)
		var resolved := WikiLinks.resolve_with(name, maps)
		outbound.append({
			"raw": name,
			"label": _title_for(resolved) if resolved != "" else name,
			"resolved": resolved,
		})
	var raw_title := String(GameManager.titles.get(rel, ""))
	return {
		"kind": "note",
		"rel": rel,
		"title": raw_title if raw_title != "" else rel.get_file().trim_suffix(".md"),
		"tags": tags_for(rel),
		"links": outbound,
		"children": [] as Array[String],
		"excerpt": String(digest.get("excerpt", "")),
		"preview": String(digest.get("preview", "")),
		"created": String(digest.get("created", "")),
		"updated": String(digest.get("updated", "")),
		"words": int(digest.get("words", 0)),
		"checklist_open": int(digest.get("checklist_open", 0)),
		"images": int(digest.get("images", 0)),
		"detail_ready": not digest.is_empty(),
	}

## Display model for a folder-as-note: the companion note's own summary plus
## the children it aggregates (titles) and the union of every descendant's tags.
static func folder_card(rel: String, digest: Dictionary) -> Dictionary:
	var stem: String = rel.trim_suffix(".md")
	var prefix := stem + "/"
	# Children carry their rel path so the card rows can navigate to them.
	var children: Array[Dictionary] = []
	var union: Array[String] = []
	for note in GameManager.notes:
		if not String(note).begins_with(prefix):
			continue
		if String(note).get_base_dir() == stem:
			var t := String(GameManager.titles.get(note, ""))
			children.append({
				"rel": String(note),
				"title": t if t != "" else String(note).get_file().trim_suffix(".md"),
			})
		for tag in GameManager.tags.get(note, []):
			var s := String(tag)
			if s != "" and not union.has(s):
				union.append(s)
	children.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["title"]) < String(b["title"]))
	union.sort()
	var own := tags_for(rel)
	for tag in union:
		if not own.has(tag):
			own.append(tag)
	var raw_title := String(GameManager.titles.get(rel, ""))
	return {
		"kind": "folder",
		"rel": rel,
		"title": raw_title if raw_title != "" else stem.get_file(),
		"tags": own,
		"links": [] as Array[Dictionary],
		"children": children,
		"child_count": children.size(),
		"excerpt": String(digest.get("excerpt", "")),
		"preview": String(digest.get("preview", "")),
		"created": String(digest.get("created", "")),
		"updated": String(digest.get("updated", "")),
		"words": int(digest.get("words", 0)),
		"checklist_open": 0,
		"images": 0,
		"detail_ready": not digest.is_empty(),
	}

## True when the path is a folder companion note (it has notes beneath it).
static func is_folder(rel: String) -> bool:
	if rel == "" or not rel.ends_with(".md"):
		return false
	var prefix: String = rel.trim_suffix(".md") + "/"
	for note in GameManager.notes:
		if String(note).begins_with(prefix):
			return true
	return false

static func tags_for(rel: String) -> Array[String]:
	var out: Array[String] = []
	for tag in GameManager.tags.get(rel, []):
		var s := String(tag)
		if s != "" and not out.has(s):
			out.append(s)
	return out

static func _title_for(rel: String) -> String:
	if rel == "":
		return ""
	var t := String(GameManager.titles.get(rel, ""))
	return t if t != "" else rel.get_file().trim_suffix(".md")