extends Node
## Headless checks for the graph focus card slice:
##   - GraphDigest extraction (excerpt/counts/tags/dates) and view-models
##   - GraphFocusCard rendering + form-factor layout + covered inset
##   - GraphView.view_rect inset framing
##   - GraphDigestStore worker read-through cache
##
## Vault safety: the digest store needs real files, so this probe assigns
## `GameManager.vault_dir` directly (never `set_vault_dir()` — that persists
## `vault.dir` into the user's settings) and points it at a disposable
## `user://neonnotes-card-probe` folder that it deletes on the way out.

const PROBE_VAULT := "user://neonnotes-card-probe"
const NOTE := """---
title: "Probe Note"
tags: godot, sync
created: 2020-03-04T10:11:12
updated: %s
---

# Heading here

First body line with a [[Other Note|link alias]] and **bold** text.
Second line: [markdown link](https://example.com) plus `code`.

- [ ] open task
- [x] done task

![img](media/a.png)
"""

var _fails := 0

func _ready() -> void:
	var check := func(name: String, ok: bool) -> void:
		print(("  ok  " if ok else "  FAIL ") + name)
		if not ok:
			_fails += 1

	_run_digest_checks(check)
	_run_view_model_checks(check)
	_run_card_checks(check)
	_run_inset_checks(check)
	await _run_store_checks(check)

	print("CARD RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)

# --------------------------------------------------------------- digest

func _run_digest_checks(check: Callable) -> void:
	var today := Time.get_datetime_string_from_system(true, false)
	var source := NOTE % today
	var d: Dictionary = GraphDigest.summarize(source)

	check.call("summary reads front-matter tags",
		(d["tags"] as Array) == (["godot", "sync"] as Array))
	check.call("summary skips front matter in the excerpt",
		not String(d["excerpt"]).contains("title:") and String(d["excerpt"]).begins_with("Heading here"))
	check.call("summary flattens wiki links in the excerpt",
		String(d["excerpt"]).contains("link alias") and not String(d["excerpt"]).contains("[["))
	check.call("summary flattens markdown links",
		GraphDigest.strip_markdown("See [markdown link](https://example.com) here")
		== "See markdown link here")
	check.call("summary drops emphasis markers", not String(d["excerpt"]).contains("**"))
	check.call("summary keeps the excerpt short", String(d["excerpt"]).length() <= GraphDigest.EXCERPT_MAX + 1)
	check.call("summary counts open checklist items", int(d["checklist_open"]) == 1)
	check.call("summary counts images", int(d["images"]) == 1)
	check.call("summary counts wiki-links out", int(d["links_out"]) == 1)
	check.call("summary counts words", int(d["words"]) > 20)
	check.call("summary keeps the created stamp", String(d["created"]) == "2020-03-04T10:11:12")
	check.call("summary keeps the updated stamp", String(d["updated"]) == today)

	check.call("human_date formats the stamp",
		GraphDigest.human_date("2020-03-04T10:11:12") == "Mar 4, 2020")
	check.call("human_date tolerates junk", GraphDigest.human_date("") == ""
		and GraphDigest.human_date("not a date") == "")
	check.call("relative_age says today for now", GraphDigest.relative_age(today) == "today")
	var old := Time.get_datetime_string_from_system(true, false)
	var unix := Time.get_unix_time_from_datetime_string(old)
	var three_days := Time.get_datetime_string_from_unix_time(int(unix) - 3 * 86400)
	check.call("relative_age counts whole days", GraphDigest.relative_age(three_days) == "3d ago")
	var thirty := Time.get_datetime_string_from_unix_time(int(unix) - 40 * 86400)
	check.call("relative_age switches to months", GraphDigest.relative_age(thirty) == "1mo ago")
	check.call("excerpt_of copes with an empty body", GraphDigest.excerpt_of("") == "")

# ------------------------------------------------------------ view models

func _run_view_model_checks(check: Callable) -> void:
	var notes: Array[String] = ["Other Note.md", "sec.md", "sec/one.md", "sec/two.md"]
	GameManager.notes = notes
	GameManager.titles = {
		"Other Note.md": "Other Note", "sec.md": "Section",
		"sec/one.md": "One", "sec/two.md": "Two",
	}
	GameManager.tags = {
		"sec.md": ["alpha"] as Array, "sec/one.md": ["beta"] as Array,
		"sec/two.md": ["alpha", "gamma"] as Array,
	}
	GameManager.links = {"sec.md": ["Other Note", "nowhere"] as Array}

	var note_model: Dictionary = GraphDigest.note_card("sec.md", {}, WikiLinks.resolve_maps())
	check.call("note card falls back to the index title", String(note_model["title"]) == "Section")
	check.call("note card carries the note tags", (note_model["tags"] as Array) == (["alpha"] as Array))
	var links: Array = note_model["links"]
	check.call("note card resolves an outgoing link", String(links[0]["label"]) == "Other Note"
		and String(links[0]["resolved"]) == "Other Note.md")
	check.call("note card keeps an unresolved link raw", String(links[1]["label"]) == "nowhere"
		and String(links[1]["resolved"]) == "" and String(links[1]["raw"]) == "nowhere")
	check.call("note card is flagged as not-yet-detailed", not bool(note_model["detail_ready"]))
	check.call("note card has no children", (note_model["children"] as Array).is_empty())

	var folder_model: Dictionary = GraphDigest.folder_card("sec.md", {"excerpt": "inside"})
	check.call("folder detected by its children", GraphDigest.is_folder("sec.md"))
	check.call("a plain note is not a folder", not GraphDigest.is_folder("Other Note.md"))
	var kids: Array = folder_model["children"]
	check.call("folder card lists child titles with paths",
		kids.size() == 2 and String(kids[0]["title"]) == "One"
		and String(kids[0]["rel"]) == "sec/one.md")
	check.call("folder card unions descendant tags",
		(folder_model["tags"] as Array) == (["alpha", "beta", "gamma"] as Array))
	check.call("folder card keeps its own excerpt", String(folder_model["excerpt"]) == "inside")
	check.call("folder card has no link rows", (folder_model["links"] as Array).is_empty())

# ------------------------------------------------------------------ card

func _run_card_checks(check: Callable) -> void:
	var host := Control.new()
	host.size = Vector2(1000, 700)
	add_child(host)
	var card: GraphFocusCard = load("res://scenes/components/graph_focus_card.tscn").instantiate()
	host.add_child(card)
	await get_tree().process_frame

	card.show_model(GraphDigest.note_card("sec.md", {
		"excerpt": "First line.", "created": "2020-03-04T10:11:12",
		"updated": Time.get_datetime_string_from_system(true, false),
		"words": 42, "checklist_open": 2, "images": 0,
	}, []))
	check.call("card renders the title", card.title_label.text == "Section")
	check.call("note card marks a note glyph", card.kind_label.text == "●")
	check.call("card renders tag chips", card.tags_chips.get_child_count() == 1)
	check.call("card shows the links header row", card.links_row.visible
		and card.links_header.text == "⇢ LINKS · 2")
	check.call("card hides the children section for a note", not card.children_scroll.visible)
	check.call("card renders the excerpt", card.excerpt_label.text == "First line.")
	check.call("card meta is human readable",
		card.meta_label.text.contains("created Mar 4, 2020")
		and card.meta_label.text.contains("edited today")
		and card.meta_label.text.contains("42 words")
		and card.meta_label.text.contains("2 open"))
	var grabber_w: float = card.children_scroll.get_v_scroll_bar().custom_minimum_size.x
	check.call("children scrollbar is touch wide", grabber_w >= 14.0)

	card.show_model(GraphDigest.folder_card("sec.md", {}))
	check.call("folder card marks a folder glyph", card.kind_label.text == "◆")
	check.call("folder card defaults to the content tab", not card.children_scroll.visible)
	(card.tab_children as BaseButton).pressed.emit()
	check.call("card lists the children on the tab", card.children_scroll.visible
		and card.children_box.get_child_count() == 2)
	check.call("card hides the links section for a folder", not card.links_row.visible)
	check.call("folder header counts the notes", card.children_header.text == "▣ 2 NOTES")

	card.close()
	check.call("close hides the card", not card.visible and card.model().is_empty())

	# Form factors.
	card.show_model(GraphDigest.note_card("sec.md", {}, []))
	card.apply_layout(Vector2(1280, 720), false, false, 44.0)
	check.call("desktop card docks top-right", card.anchor_left == 1.0 and card.anchor_top == 0.0
		and card.offset_top == 44.0 + 12.0 and card.offset_right == -12.0)
	card.apply_layout(Vector2(800, 400), true, false, 44.0)
	check.call("landscape phone card is a right rail", card.anchor_top == 0.0 and card.anchor_bottom == 1.0
		and card.offset_bottom == -12.0 and card.offset_top == 12.0)
	card.apply_layout(Vector2(400, 800), true, true, 44.0)
	check.call("portrait phone card is a bottom sheet", card.anchor_left == 0.0 and card.anchor_top == 1.0
		and card.anchor_bottom == 1.0 and card.offset_bottom == -12.0)
	var sheet_h: float = -card.offset_top + card.offset_bottom
	check.call("portrait sheet is about a third of the screen",
		sheet_h > 250.0 and sheet_h < 290.0)
	# Interactive rows: child rows navigate, tag chips filter.
	var child_rels: Array = []
	var tag_picks: Array = []
	card.child_selected.connect(func(rel: String) -> void: child_rels.append(rel))
	card.tag_selected.connect(func(tag: String) -> void: tag_picks.append(tag))
	var folder_model2: Dictionary = GraphDigest.folder_card("sec.md", {})
	card.show_model(folder_model2)
	var rows := card.children_box.get_children()
	(rows[0] as BaseButton).pressed.emit()
	tags_chips_press(card)
	check.call("child row press carries the note path", child_rels == (["sec/one.md"] as Array))
	check.call("tag chip press carries the tag", tag_picks == (["alpha"] as Array))

	# The links header button opens the all-links page instead of listing here.
	var opened := [false]
	card.links_opened.connect(func(): opened[0] = true)
	var many_links: Array = []
	for i in 25:
		many_links.append({"raw": "t%02d" % i, "label": "T%02d" % i, "resolved": "" if i == 0 else "r%02d.md" % i})
	card.show_model({"kind": "note", "title": "L", "tags": [], "children": [],
		"links": many_links, "excerpt": "", "created": "", "updated": ""})
	check.call("links header counts every link", card.links_header.text == "⇢ LINKS · 25")
	card.links_btn.pressed.emit()
	check.call("links button opens the links page", opened[0])
	card.show_model({"kind": "note", "title": "L", "tags": [], "children": [],
		"links": [], "excerpt": "", "created": "", "updated": ""})
	check.call("no links means no header row", not card.links_row.visible)

	# Folder card tabs: content first, children on the second tab.
	card.show_model(GraphDigest.folder_card("sec.md", {"excerpt": "inside"}))
	check.call("folder card starts on the content tab",
		card.excerpt_label.visible and not card.children_scroll.visible)
	(card.tab_children as BaseButton).pressed.emit()
	check.call("children tab shows the list", card.children_scroll.visible
		and not card.excerpt_label.visible)
	(card.tab_content as BaseButton).pressed.emit()
	check.call("content tab shows the excerpt", card.excerpt_label.visible
		and not card.children_scroll.visible)
	card.show_model(GraphDigest.note_card("sec.md", {}, []))
	check.call("note card has no tabs", not card.tabs_row.visible)

	host.queue_free()

	# Nav bar component: mirrors nav_state and emits the view's action strings.
	var bar: GraphNavBar = load("res://scenes/components/graph_nav_bar.tscn").instantiate()
	add_child(bar)
	await get_tree().process_frame
	var actions: Array = []
	bar.nav_action.connect(func(action: String) -> void: actions.append(action))
	bar.update_state({"page": 0, "page_count": 3,
		"crumbs": [{"key": "", "label": "Overview"}, {"key": "sec", "label": "Section"}],
		"in_scope": true})
	check.call("pager label mirrors state", bar.page_label.text == "1/3")
	check.call("back pager disabled on the first page", bar.first_btn.disabled and bar.prev_btn.disabled)
	var current_btn := bar.crumbs_box.get_child(2) as Button  # [crumb, /, crumb]
	var crumb_btn := bar.crumbs_box.get_child(0) as Button
	check.call("current crumb is not a jump target", current_btn.disabled and not crumb_btn.disabled)
	crumb_btn.pressed.emit()  # the homepage crumb jumps to the overview
	bar.update_state({"page": 1, "page_count": 3, "crumbs": [], "in_scope": true})
	check.call("forward pager enabled mid-pages", not bar.next_btn.disabled and not bar.last_btn.disabled)
	bar.last_btn.pressed.emit()
	check.call("nav actions reach the view", actions == (["home", ">>"] as Array))
	bar.update_state({"page": 0, "page_count": 1, "crumbs": [{"key": "", "label": "Overview"}], "in_scope": false})
	check.call("pager hides on a single page", not bar.pager_box.visible)
	bar.update_state({"page": 0, "page_count": 2, "crumbs": [], "in_scope": true})
	check.call("pager returns when pages grow", bar.pager_box.visible)
	bar.queue_free()

	# Links page: every link at once; rows report target + resolution.
	var page: GraphLinksPage = load("res://scenes/components/graph_links_page.tscn").instantiate()
	add_child(page)
	await get_tree().process_frame
	var picked: Array = []
	page.link_activated.connect(func(target: String, resolved: String) -> void:
		picked.append([target, resolved]))
	page.open("Section", [
		{"raw": "Other Note", "label": "Other Note", "resolved": "Other Note.md"},
		{"raw": "nowhere", "label": "nowhere", "resolved": ""},
	])
	check.call("links page lists every link", page.list.get_child_count() == 2)
	(page.list.get_child(0) as BaseButton).pressed.emit()
	(page.list.get_child(1) as BaseButton).pressed.emit()
	check.call("links page rows report target and resolution",
		picked == ([["Other Note", "Other Note.md"], ["nowhere", ""]] as Array))
	page.queue_free()

## Helper: press the card's first tag chip.
func tags_chips_press(card: GraphFocusCard) -> void:
	var chip := card.tags_chips.get_child(0) as BaseButton
	chip.pressed.emit()

# ------------------------------------------------------------------ inset

func _run_inset_checks(check: Callable) -> void:
	var card: GraphFocusCard = load("res://scenes/components/graph_focus_card.tscn").instantiate()
	add_child(card)
	await get_tree().process_frame
	var none: Dictionary = card.covered_inset(Vector2(1280, 720), false, false)
	check.call("desktop card claims no map space",
		float(none["right"]) == 0.0 and float(none["bottom"]) == 0.0)
	var sheet: Dictionary = card.covered_inset(Vector2(400, 800), true, true)
	check.call("portrait sheet claims bottom space",
		float(sheet["bottom"]) > 250.0 and float(sheet["right"]) == 0.0)
	var rail: Dictionary = card.covered_inset(Vector2(800, 400), true, false)
	check.call("landscape rail claims right space",
		float(rail["right"]) > 240.0 and float(rail["bottom"]) == 0.0)
	card.queue_free()

	var gv: GraphView = load("res://scripts/render/graph_view.gd").new()
	gv.size = Vector2(600, 400)
	add_child(gv)
	await get_tree().process_frame
	check.call("graph view rect defaults to the full control",
		gv.view_rect() == Rect2(Vector2.ZERO, Vector2(600, 400)))
	gv.view_inset = {"left": 0.0, "top": 0.0, "right": 200.0, "bottom": 0.0}
	check.call("graph view rect shrinks by the inset", gv.view_rect().size == Vector2(400, 400))
	check.call("focus framing centres inside the free area",
		gv.view_rect().get_center() == Vector2(200, 200))

	# Phone overview default: closer than fit-all, portrait or landscape.
	var notes2: Array[String] = ["r.md"]
	for i in 30:
		notes2.append("r/n%02d.md" % i)
	var saved_notes3: Array[String] = GameManager.notes
	GameManager.notes = notes2
	gv.size = Vector2(430, 940)
	gv.mobile_fit = true
	gv.open("")
	await get_tree().process_frame
	await get_tree().process_frame
	check.call("phone overview opens closer than fit-all", gv._map_scale > 1.0)
	check.call("fit-all stays reachable by zooming out", gv._min_zoom < gv._map_scale)
	var portrait_scale: float = gv._map_scale
	gv.size = Vector2(940, 430)
	gv._rebuild_keys()
	gv._layout_points()
	gv._fit_to_view()
	check.call("landscape floor matches portrait (short edge based)",
		absf(gv._map_scale - portrait_scale) < 0.01)
	gv.mobile_fit = false
	gv._fit_to_view()
	check.call("desktop still fits everything", absf(gv._map_scale - gv._min_zoom) < 0.0001)
	GameManager.notes = saved_notes3
	gv.queue_free()

	# GraphView side of the card: outside taps drop the focus (blur) and the
	# child list can steer the map to a node.
	var gv2: GraphView = load("res://scripts/render/graph_view.gd").new()
	gv2.size = Vector2(800, 600)
	add_child(gv2)
	await get_tree().process_frame
	var blurs := [0]
	gv2.blur_cb = func() -> void: blurs[0] += 1
	var shot_notes: Array[String] = ["hub.md", "sec.md", "sec/one.md", "sec/two.md"]
	var saved_notes2: Array[String] = GameManager.notes
	var saved_links2: Dictionary = GameManager.links
	GameManager.notes = shot_notes
	GameManager.links = {}
	gv2.open("")
	await get_tree().process_frame
	await get_tree().process_frame
	gv2._select("sec")  # opens the circle menu on the folder node
	check.call("focus_note selects a mapped note", gv2.focus_note("sec/one.md"))
	check.call("focus moved the selection to the child", gv2._selected == "sec/one.md")
	gv2._menu_open = true
	gv2._close_menu()
	check.call("outside press closes the menu and blurs", blurs[0] == 1)
	check.call("focus_note falls back when the note is unmapped",
		not gv2.focus_note("nope.md"))
	GameManager.notes = saved_notes2
	GameManager.links = saved_links2
	gv2.queue_free()

# ------------------------------------------------------------------ store

func _run_store_checks(check: Callable) -> void:
	var abs := ProjectSettings.globalize_path(PROBE_VAULT)
	DirAccess.make_dir_recursive_absolute(abs)
	# Assign the field directly: set_vault_dir() would persist vault.dir.
	GameManager.vault_dir = PROBE_VAULT
	var f := FileAccess.open(PROBE_VAULT.path_join("probe.md"), FileAccess.WRITE)
	f.store_string(NOTE % Time.get_datetime_string_from_system(true, false))
	f.close()

	var store := GraphDigestStore.new()
	add_child(store)  # _ready starts the worker against the probe vault
	# Connected before the request: delivery is deferred, and a signal that
	# fires before the listener exists would be missed.
	# A one-element array, not a plain String: GDScript lambdas capture locals
	# by value, so assigning to a captured String inside the handler would be
	# invisible out here.
	var got := [""]
	var handler := func(rel: String) -> void: got[0] = rel
	store.digest_ready.connect(handler)
	check.call("store reports a cache miss on the first ask",
		store.request("probe.md").is_empty())
	var frames := 0
	while got[0] == "" and frames < 240:
		await get_tree().process_frame
		frames += 1
	check.call("store delivers the digest off-thread", got[0] == "probe.md")
	var cached: Dictionary = store.request("probe.md")
	check.call("store caches the summary", String(cached.get("excerpt", "")).begins_with("Heading here"))
	check.call("a cached digest answers without waiting", int(cached.get("images", 0)) == 1)
	store.invalidate("probe.md")
	check.call("invalidate drops the entry", store.request("probe.md").is_empty())
	# queue_free (not free): a deferred delivery may still be in flight for
	# this frame, and _exit_tree() is what joins the worker thread.
	store.queue_free()
	await get_tree().process_frame

	DirAccess.remove_absolute(abs.path_join("probe.md"))
	DirAccess.remove_absolute(abs)
	GameManager.vault_dir = GameManager.VAULT_DIR