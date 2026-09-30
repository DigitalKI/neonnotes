#!/usr/bin/env python3
"""Generate a large NeonNotes test vault from the official Godot documentation.

Every class in the selected godot-docs branch becomes one NeonNotes note:

    <vault>/<branch>/<ClassName>.md

with YAML front matter (title + a controlled tag vocabulary), a plain-Markdown
body converted from the official reST class reference, and `[[wiki-link]]`s to
the classes it references. Folder companion notes (`<branch>.md`) are written
too, so the tree's folder-as-note merge has something to show.

Why: NeonNotes needs a big, *realistic* vault to exercise the boot scan, the
tag/search indexes, backlinks and the knowledge graph at a scale no hand-made
fixture reaches (~1000 notes, dozens of tags, thousands of links).

The vault is NEVER the user's real vault: the default output lives under
`build/` (gitignored). Point the app at it explicitly, e.g.

    NEONNOTES_VAULT=$PWD/build/godot-docs-vault godot --path .

Usage:
    tools/gen_godot_docs_vault.py                     # build/ default
    tools/gen_godot_docs_vault.py --out /tmp/nn-docs
    tools/gen_godot_docs_vault.py --branch 4.7 --offline   # cache only
    tools/gen_godot_docs_vault.py --limit 50          # quick smoke build
    tools/gen_godot_docs_vault.py --tutorials scripting,ui  # + tutorial subset

The reST sources are cached under build/.godot-docs-cache/<branch>/ so repeat
runs are offline and fast. Conversion is line-based (hand-rolled; the repo has
no docutils/pandoc and shouldn't grow one) and deliberately lossy: it keeps
headings, paragraphs, lists, grid tables, code blocks and inline roles.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

REPO = "godotengine/godot-docs"
RAW = "https://raw.githubusercontent.com/%s" % REPO
API = "https://api.github.com/repos/%s" % REPO

# Deterministic front-matter stamps so re-generating is byte-identical.
STAMP = "2026-09-30T13:11:00"

# ---------------------------------------------------------------------------
# Tag vocabulary
# ---------------------------------------------------------------------------

# Inheritance hub -> folder. The first ancestor (nearest first) that is a hub
# decides the folder, so Control lands in ui/ before Node can claim it.
HUBS = [
	("Node3D", "3d"),
	("Node2D", "2d"),
	("Control", "ui"),
	("CanvasItem", "ui"),
	("AnimationMixer", "animation"),
	("AnimationRootNode", "animation"),
	("AnimationNode", "animation"),
	("Node", "node"),
	("Resource", "resource"),
	("RefCounted", "refcounted"),
	("MainLoop", "core"),
	("Object", "core"),
]

BRANCH_LABELS = {
	"core": "Core",
	"variant": "Built-in Types",
	"refcounted": "RefCounted",
	"resource": "Resources",
	"node": "Nodes",
	"2d": "2D",
	"3d": "3D",
	"ui": "UI",
	"animation": "Animation",
}

# Folder names must NOT equal any class name: the folder companion note
# ("<folder>.md") shares the wiki-link basename namespace, so a "node/" folder
# would steal every [[Node]] link from the Node class note. These avoid the
# colliding classes (Node, Resource, RefCounted, Variant, Animation).
BRANCH_FOLDERS = {
	"core": "core",
	"variant": "built-in-types",
	"refcounted": "refcounted-types",
	"resource": "resources",
	"node": "nodes",
	"2d": "2d",
	"3d": "3d",
	"ui": "ui",
	"animation": "animations",
}

# Topic tags are heuristic keyword matches over name + brief + description.
TOPIC_RULES = [
	("physics", r"physic|collision|\brigid|\bjoint|\bshape\b|\bbody\b|raycast|\barea\b|trigger"),
	("audio", r"audio|\bsound\b|\bmusic\b|microphone|speaker|\bbus\b"),
	("rendering", r"render|material|shader|\bmesh\b|texture|\blight\b|camera|viewport|environment|particle|sky|fog|decal|\bgpu\b|canvas"),
	("networking", r"multiplay|network|enet|packet|\bhttp\b|websocket|\brpc\b|socket|\bpeer\b|\btcp\b|\budp\b"),
	("input", r"\binput\b|keyboard|\bmouse\b|joypad|\bjoy\b|touch|\baction\b|gesture"),
	("animation", r"animat|\btween\b|skeleton|\bbone\b|\bik\b|\brig\b|keyframe"),
	("navigation", r"navigation|navmesh|astar|pathfind|\bnav\b"),
	("math", r"vector|transform|matrix|quaternion|basis|\bplane\b|\baabb\b|\brect\b|\bmath\b|geometry|random|\bcurve\b|noise|\bcolor\b|projection|interpolat"),
	("text", r"\btext\b|\bfont\b|\bstring\b|label|bbcode|richtext|locale|translat|typography"),
	("editor", r"editor|inspector|\bplugin\b|gizmo|\bimport\b"),
	("scripting", r"\bscript\b|expression|gdscript|\bclass\b|\bmethod\b|function|callable|\bsignal\b|property"),
	("xr", r"\bxr\b|openxr|webxr|\bvr\b|\bar\b|hand.?track"),
	("filesystem", r"\bfile\b|directory|filesystem|\bpath\b|config|\bos\.|stream"),
	("serialization", r"serializ|\bjson\b|\bxml\b|packedscene|\bresource\b|marsh"),
	("concurrency", r"\bthread\b|mutex|semaphore|worker|async|await"),
	("debugging", r"\bdebug\b|profil|\berror\b|logger|\bassert\b"),
	("platform", r"\bos\b|platform|windows|linux|macos|android|\bios\b|\bweb\b|display.?server"),
	("ui", r"control|button|dialog|container|theme|\bgui\b|\bmenu\b|panel|popup|\bwindow\b|\btab\b|tooltip"),
]

# Curated "start here" classes from the godot-project skill's API index.
POPULAR = {
	"AnimationPlayer", "Area2D", "Area3D", "AudioStreamPlayer", "Button",
	"Camera2D", "Camera3D", "CharacterBody2D", "CharacterBody3D",
	"CollisionShape2D", "CollisionShape3D", "Control", "Environment",
	"HBoxContainer", "Input", "Label", "Light3D", "NavigationAgent2D",
	"NavigationAgent3D", "Node", "Node2D", "Node3D", "PackedScene", "Resource",
	"RigidBody2D", "RigidBody3D", "SceneTree", "Sprite2D", "Timer", "Tween",
	"VBoxContainer", "WorldEnvironment",
}

SECTION_LABELS = {
	"Properties": ["Type", "Property", "Default"],
	"Methods": ["Returns", "Method"],
	"Signals": ["Signal"],
	"Constants": ["Type", "Constant", "Value"],
}

# ---------------------------------------------------------------------------
# Fetching + cache
# ---------------------------------------------------------------------------


def fetch(url: str) -> str:
	req = urllib.request.Request(url, headers={"User-Agent": "neonnotes-docs-vault"})
	with urllib.request.urlopen(req, timeout=60) as resp:
		return resp.read().decode("utf-8")


def class_index(cache: Path, branch: str, offline: bool) -> list[str]:
	"""Return the sorted list of class_*.rst paths at the branch root."""
	cached = cache / "_classes.json"
	if cached.exists():
		return json.loads(cached.read_text())
	if offline:
		sys.exit("error: no cached class index in %s (drop --offline)" % cache)
	root = json.loads(fetch("%s/git/trees/%s" % (API, branch)))
	classes_sha = next(t["sha"] for t in root["tree"] if t["path"] == "classes")
	tree = json.loads(fetch("%s/git/trees/%s" % (API, classes_sha)))
	names = sorted(
		t["path"] for t in tree["tree"]
		if t["path"].startswith("class_") and t["path"].endswith(".rst")
	)
	cache.mkdir(parents=True, exist_ok=True)
	cached.write_text(json.dumps(names, indent=1))
	return names


def ensure_rst(cache: Path, branch: str, name: str, offline: bool) -> str | None:
	path = cache / "classes" / name
	if path.exists() and path.stat().st_size > 0:
		return path.read_text(encoding="utf-8")
	if offline:
		return None
	try:
		text = fetch("%s/%s/classes/%s" % (RAW, branch, name))
	except Exception:
		return None
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(text, encoding="utf-8")
	return text


# ---------------------------------------------------------------------------
# reST -> Markdown
# ---------------------------------------------------------------------------

_SUBST_DEF = re.compile(r"^\.\. \|(\w+)\| replace::\s*(.*)$")
_ABBR = re.compile(r":abbr:`([^`]*?)\s*\([^`]*\)`")
_ROLE = re.compile(r":([a-z-]+):`([^`]*)`")
_ICON = re.compile(r":ref:`\U0001f517<[^>]*>`")
_BOILER = (
	":github_url:", ".. DO NOT EDIT", ".. Generated", ".. Generator:",
	".. XML source:", ".. rst-class::", ".. _", ".. table::", ":widths:",
	".. tabs::",
)  # NOTE: `.. only::`/`.. toctree::` fall through to the generic directive
# handler so their indented bodies are consumed, not leaked as prose.


def _indent(line: str) -> int:
	return len(line) - len(line.lstrip(" \t"))


def _dedent(block: list[str]) -> list[str]:
	if not block:
		return block
	pad = min(_indent(l) for l in block if l.strip())
	return [l[pad:] if len(l) >= pad else "" for l in block]


def _unescape(text: str) -> str:
	# reST escapes markup with a backslash: "\ **Note:**", "\ (" in signatures.
	return re.sub(r"\\(.)", r"\1", text)


def _role_sub(subst: dict[str, str]):
	def repl(m: re.Match) -> str:
		role, content = m.group(1), m.group(2)
		if role == "ref":
			if content.startswith("\U0001f517"):
				return ""
			if "<" in content and content.endswith(">"):
				label, target = content.rsplit("<", 1)
				target = target[:-1].strip()
				label = label.strip()
			else:
				label = target = content.strip()
			if not label:
				label = target
			if target.startswith("class_"):
				rest = target[len("class_"):]
				if "_" not in rest:
					return "[[%s]]" % rest
				return "`%s`" % label
			if target.startswith("enum_"):
				return "`%s`" % label
			return label
		if role == "doc":
			return content.split("<")[0].strip() or content
		if role == "abbr":
			return content.split(" (")[0].strip()
		return content

	return repl


def convert_inline(text: str, subst: dict[str, str]) -> str:
	# Protect literal inline code first so roles can't touch it.
	lits: list[str] = []

	def stash(m: re.Match) -> str:
		lits.append(m.group(1))
		return "\x00%d\x00" % (len(lits) - 1)

	text = re.sub(r"``(.+?)``", stash, text)
	text = _ICON.sub("", text)
	# reST hyperlinks: `Title <url>`__  and named refs `text`_
	text = re.sub(r"`([^`<>]+?)\s*<([^`>]+)>`__?", r"[\1](\2)", text)
	text = re.sub(r"`([^`<>]+?)`__?", r"\1", text)
	text = _ROLE.sub(_role_sub(subst), text)
	text = re.sub(r"\x00(\d+)\x00", lambda m: "`%s`" % lits[int(m.group(1))], text)
	for name, value in subst.items():
		text = text.replace("|%s|" % name, value)
	text = _unescape(text)
	return text.strip()


def render_table(block: list[str], section: str, subst: dict[str, str]) -> list[str]:
	rows: list[list[str]] = []
	for line in block:
		s = line.rstrip()
		if not s:
			continue
		stripped = s.strip()
		if stripped.startswith("+"):
			continue
		if not stripped.startswith("|"):
			continue
		# Substitutions contain pipes (|bitfield|, |const|) and would be read as
		# cell separators — fold them into their display text before splitting.
		for name, value in subst.items():
			stripped = stripped.replace("|%s|" % name, value)
		inner = stripped[1:-1] if stripped.endswith("|") else stripped[1:]
		rows.append([c.strip() for c in inner.split("|")])
	if not rows:
		return []
	labels = SECTION_LABELS.get(section, [])
	ncols = len(labels) if labels else max(len(r) for r in rows)
	rows = [r + [""] * (ncols - len(r)) for r in rows]
	labels = labels[:ncols] if len(labels) >= ncols else labels + ["Value"] * (ncols - len(labels))
	header = "| " + " | ".join(labels) + " |"
	sep = "|" + "---|" * ncols
	out = [header, sep]
	for r in rows:
		out.append("| " + " | ".join(convert_inline(c, subst) for c in r) + " |")
	return out


def convert_rst(text: str) -> tuple[dict, dict]:
	"""Return (sections, info) for one reST file."""
	subst: dict[str, str] = {}
	raw_lines = text.split("\n")
	lines: list[str] = []
	i = 0
	while i < len(raw_lines):
		raw = raw_lines[i]
		s = raw.strip()
		m = _SUBST_DEF.match(s)
		if m:
			body = m.group(2)
			a = _ABBR.search(body)
			val = a.group(1).strip() if a else m.group(1)
			subst[m.group(1)] = val
			i += 1
			continue
		if s == "" or s == "----":
			lines.append("")
			i += 1
			continue
		if any(s.startswith(p) for p in _BOILER):
			i += 1
			continue
		m = re.match(r"^\.\. (?:code|code-tab|code-block)::\s*(\S+)?", s)
		if m:
			lang = m.group(1) or ""
			base = _indent(raw)
			i += 1
			while i < len(raw_lines) and raw_lines[i].strip() == "":
				i += 1
			block: list[str] = []
			while i < len(raw_lines) and (
				raw_lines[i].strip() == "" or _indent(raw_lines[i]) > base
			):
				block.append(raw_lines[i])
				i += 1
			lines.append("```" + lang)
			lines.extend(_dedent(block))
			lines.append("```")
			lines.append("")
			continue
		if s.startswith(".. note::") or s.startswith(".. warning::"):
			prefix = "Note" if s.startswith(".. note::") else "Warning"
			first = s.split("::", 1)[1].strip()
			base = _indent(raw)
			i += 1
			extra: list[str] = []
			while i < len(raw_lines) and (
				raw_lines[i].strip() == "" or _indent(raw_lines[i]) > base
			):
				extra.append(raw_lines[i].strip())
				i += 1
			body = " ".join([first] + [e for e in extra if e]).strip()
			lines.append("> **%s:** %s" % (prefix, body))
			lines.append("")
			continue
		if s.startswith(".."):
			base = _indent(raw)
			i += 1
			while i < len(raw_lines) and (
				raw_lines[i].strip() == "" or _indent(raw_lines[i]) > base
			):
				i += 1
			continue
		lines.append(raw)
		i += 1

	# Headings + sections.
	md_lines: list[str] = []
	sections: dict[str, list[str]] = {"__intro__": []}
	current = "__intro__"
	in_code = False
	i = 0
	while i < len(lines):
		line = lines[i]
		if line.strip().startswith("```"):
			in_code = not in_code
			md_lines.append(line.rstrip())
			i += 1
			continue
		if in_code:
			md_lines.append(line.rstrip())
			i += 1
			continue
		nxt = lines[i + 1] if i + 1 < len(lines) else ""
		stripped_nxt = nxt.strip()
		if (
			line.strip() and stripped_nxt
			and len(stripped_nxt) >= max(2, len(line.strip()))
			and set(stripped_nxt) <= {"=", "-", "~"}
		):
			level = "#" if stripped_nxt[0] == "=" else "##"
			body = convert_inline(line.strip(), subst)
			sections[current] = md_lines
			current = body if level == "##" else current
			md_lines = ["%s %s" % (level, body), ""]
			i += 2
			continue
		if line.strip() == "":
			md_lines.append("")
			i += 1
			continue
		stripped = line.strip()
		if stripped.startswith("+") and set(stripped) <= set("+-="):
			# collect a grid table
			block = [line]
			j = i + 1
			while j < len(lines):
				nxt_raw = lines[j]
				ns = nxt_raw.strip()
				if ns.startswith("+") or ns.startswith("|"):
					block.append(nxt_raw)
					j += 1
				elif ns == "":
					j += 1
					break
				else:
					break
			md_lines.extend(render_table(block, current, subst))
			md_lines.append("")
			i = j
			continue
		md_lines.append(convert_inline(line.rstrip(), subst))
		i += 1
	sections[current] = md_lines

	# Info: name, inheritance chain, section presence.
	name = ""
	for s, body in sections.items():
		if s == "__intro__":
			for ln in body:
				if ln.startswith("# "):
					name = ln[2:].strip()
					break
		if name:
			break

	chain: list[str] = []
	for ln in sections.get("__intro__", []):
		if ln.startswith("**Inherits:**"):
			chain = re.findall(r"\[\[([^\]]+)\]\]", ln)
			break

	present = {s for s, body in sections.items() if s != "__intro__" and any(b.strip() for b in body)}
	brief = ""
	for ln in sections.get("__intro__", []):
		t = ln.strip()
		if not t or t.startswith("#") or t.startswith("**"):
			continue
		brief = t
		break

	desc_head = ""
	for s, body in sections.items():
		if s == "Description":
			desc_head = " ".join(" ".join(body).split())[:700]
			break

	info = {
		"name": name,
		"chain": chain,
		"present": present,
		"brief": brief,
		"desc_head": desc_head,
		"raw": text,
	}
	return sections, info


def branch_of(name: str, chain: list[str]) -> str:
	for candidate in [name] + chain:
		for hub, folder in HUBS:
			if candidate == hub:
				return folder
	if not chain:
		return "variant"
	return "core"


def topic_tags(hay: str) -> list[str]:
	hay = hay.lower()
	tags: list[str] = []
	for tag, pattern in TOPIC_RULES:
		if re.search(pattern, hay):
			tags.append(tag)
	return tags


def make_tags(info: dict) -> list[str]:
	present = info["present"]
	# Heuristics read the class's own summary, not the whole reference — a big
	# class mentions half the engine, which made the tags meaningless.
	head = " ".join([info["name"], info.get("brief", ""), info.get("desc_head", "")])
	tags = ["godot", "api", "class", branch_of(info["name"], info["chain"])]
	tags += topic_tags(head)
	if info["name"] in POPULAR:
		tags.append("popular")
	if "**Deprecated:**" in head:
		tags.append("deprecated")
	if "**Experimental:**" in head:
		tags.append("experimental")
	if "abstract base class" in head.lower():
		tags.append("abstract")
	if "Methods" in present:
		tags.append("has-methods")
	if "Properties" in present:
		tags.append("has-properties")
	if "Signals" in present:
		tags.append("has-signals")
	if "Constants" in present:
		tags.append("has-constants")
	if "Enumerations" in present:
		tags.append("has-enums")
	# Stable, de-duplicated, generic tags last.
	seen: dict[str, None] = {}
	for t in tags:
		seen.setdefault(t, None)
	return list(seen)


def render_note(info: dict, sections: dict, tags: list[str] | None = None) -> str:
	tags = list(dict.fromkeys(tags or make_tags(info)))
	title = info["name"]
	body = "\n".join(sections.get("__intro__", [])).strip()
	for name, lines in sections.items():
		if name == "__intro__":
			continue
		block = "\n".join(lines).strip()
		if not block:
			continue
		body += "\n\n" + block
	body = re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"
	header = [
		"---",
		'title: "%s"' % title.replace('\\', '\\\\').replace('"', '\\"'),
		"tags: " + ", ".join(tags),
		"created: " + STAMP,
		"updated: " + STAMP,
		"---",
		"",
	]
	return "\n".join(header) + body


# ---------------------------------------------------------------------------
# Vault emission
# ---------------------------------------------------------------------------


def safe_filename(name: str) -> str:
	return re.sub(r"[^A-Za-z0-9_@.-]", "_", name) or "Class"


def plain_heading_body(title: str, text: str, tags: list[str]) -> str:
	header = [
		"---",
		'title: "%s"' % title,
		"tags: " + ", ".join(tags),
		"created: " + STAMP,
		"updated: " + STAMP,
		"---",
		"",
		"# " + title,
		"",
	]
	return "\n".join(header) + text.strip() + "\n"


def main() -> int:
	root = Path(__file__).resolve().parent.parent
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("--out", default=str(root / "build" / "godot-docs-vault"))
	ap.add_argument("--cache", default=str(root / "build" / ".godot-docs-cache"))
	ap.add_argument("--branch", default="4.7")
	ap.add_argument("--offline", action="store_true", help="use cache only, no network")
	ap.add_argument("--limit", type=int, default=0, help="only generate the first N classes")
	ap.add_argument("--tutorials", default="", help="comma-separated tutorial areas to add")
	ap.add_argument("--keep", action="store_true", help="don't wipe the output first")
	args = ap.parse_args()

	cache = Path(args.cache) / args.branch
	out = Path(args.out).resolve()

	names = class_index(cache, args.branch, args.offline)
	if args.limit:
		names = names[: args.limit]

	print("[docs-vault] %s @ %s -> %s (%d classes)" % (REPO, args.branch, out, len(names)))
	print("[docs-vault] cache: %s" % cache)

	with ThreadPoolExecutor(max_workers=16) as pool:
		texts = list(pool.map(lambda n: ensure_rst(cache, args.branch, n, args.offline), names))

	if not args.keep and out.exists():
		import shutil

		shutil.rmtree(out)
	out.mkdir(parents=True, exist_ok=True)

	counts: dict[str, int] = {}
	tag_counts: dict[str, int] = {}
	link_total = 0
	notes = 0
	for name, text in zip(names, texts):
		if not text:
			continue
		sections, info = convert_rst(text)
		if not info["name"]:
			continue
		folder = branch_of(info["name"], info["chain"])
		tags = make_tags(info)
		path = out / BRANCH_FOLDERS[folder] / (safe_filename(info["name"]) + ".md")
		path.parent.mkdir(parents=True, exist_ok=True)
		path.write_text(render_note(info, sections), encoding="utf-8")
		counts[folder] = counts.get(folder, 0) + 1
		for t in tags:
			tag_counts[t] = tag_counts.get(t, 0) + 1
		link_total += len(set(re.findall(r"\[\[([^\]]+)\]\]", "\n".join(sections.get("__intro__", [])))))
		notes += 1

	# Folder companion notes (folder-as-note merge).
	for folder, label in BRANCH_LABELS.items():
		if folder not in counts:
			continue
		dir_name = BRANCH_FOLDERS[folder]
		children = sorted(p.stem for p in (out / dir_name).glob("*.md"))
		body = "Classes in the **%s** group (inheritance branch).\n\n" % label
		body += "".join("- [[%s]]\n" % c for c in children)
		(out / ("%s.md" % dir_name)).write_text(
			plain_heading_body(label, body, ["godot", "api", "folder", folder]), encoding="utf-8"
		)

	# Optional tutorial subset -> <area>/<slug>.md
	tut_count = 0
	if args.tutorials:
		for area in [a.strip() for a in args.tutorials.split(",") if a.strip()]:
			tut_count += _generate_tutorials(cache, args.branch, out, area, args.offline)

	# Home index.
	lines = [
		"NeonNotes test vault generated from the official Godot %s documentation." % args.branch,
		"",
		"## Groups",
		"",
	]
	for folder, label in BRANCH_LABELS.items():
		if folder in counts:
			lines.append("- [[%s]] — %s, %d classes" % (BRANCH_FOLDERS[folder], label, counts[folder]))
	if tut_count:
		lines.append("- [[tutorials]] — %d tutorial pages" % tut_count)
	lines += [
		"",
		"## Tag vocabulary",
		"",
		"| tag | notes |",
		"|---|---|",
	]
	for tag, n in sorted(tag_counts.items(), key=lambda kv: (-kv[1], kv[0])):
		lines.append("| `#%s` | %d |" % (tag, n))
	lines += [
		"",
		"## Popular classes",
		"",
		"- " + ", ".join("[[%s]]" % c for c in sorted(POPULAR)),
	]
	(out / "Home.md").write_text(
		plain_heading_body("Godot Docs Vault", "\n".join(lines), ["godot", "api", "index"]),
		encoding="utf-8",
	)

	total = sum(p.stat().st_size for p in out.rglob("*.md"))
	print("[docs-vault] wrote %d notes + %d folder notes + %d tutorials, %d files, %.1f MiB"
		% (notes, len([f for f in counts]), tut_count, len(list(out.rglob('*.md'))), total / 1048576))
	print("[docs-vault] tags: %d distinct — %s" % (len(tag_counts), ", ".join(sorted(tag_counts))))
	print("[docs-vault] open it with: NEONNOTES_VAULT=%s godot --path %s" % (out, root))
	return 0


def _slug(title: str) -> str:
	return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "page"


def _generate_tutorials(cache: Path, branch: str, out: Path, area: str, offline: bool) -> int:
	"""Fetch tutorials/<area>/*.rst and emit one note each under tutorials/<area>/."""
	idx = cache / "tutorials" / ("%s.json" % area)
	if idx.exists():
		files = json.loads(idx.read_text())
	elif offline:
		return 0
	else:
		try:
			items = json.loads(fetch("%s/contents/tutorials/%s?ref=%s" % (API, area, branch)))
		except Exception:
			return 0
		files = [i["path"] for i in items if i.get("type") == "file" and i["name"].endswith(".rst")]
		idx.parent.mkdir(parents=True, exist_ok=True)
		idx.write_text(json.dumps(files, indent=1))
	n = 0
	for p in files:
		local = cache / p
		if local.exists():
			text = local.read_text(encoding="utf-8")
		elif offline:
			continue
		else:
			try:
				text = fetch("%s/%s/%s" % (RAW, branch, p))
			except Exception:
				continue
			local.parent.mkdir(parents=True, exist_ok=True)
			local.write_text(text, encoding="utf-8")
		sections, info = convert_rst(text)
		# Tutorials have no class name/inherits; take the first H1 as the title.
		title = ""
		for key, body in sections.items():
			h = next((l for l in body if l.startswith("# ")), None)
			if h:
				title = h[2:].strip()
				break
		if not title:
			title = Path(p).stem.replace("_", " ").title()
		title = " ".join(title.split())
		dest = out / "tutorials" / area / (_slug(Path(p).stem) + ".md")
		dest.parent.mkdir(parents=True, exist_ok=True)
		dest.write_text(
			render_note(
				{"name": title, "chain": [], "present": set(), "brief": "", "desc_head": text[:700], "raw": text},
				sections,
				["godot", "api", "tutorial", area] + topic_tags(title + " " + text[:700]),
			),
			encoding="utf-8",
		)
		n += 1
	if n:
		areas = sorted({p.parts[-2] for p in out.glob("tutorials/*/*.md")})
		body = "Official Godot manual pages.\n\n" + "".join(
			"- `%s` — %d pages\n" % (a, len(list((out / "tutorials" / a).glob("*.md")))) for a in areas
		)
		(out / "tutorials.md").write_text(
			plain_heading_body("Tutorials", body, ["godot", "api", "folder", "tutorial"]),
			encoding="utf-8",
		)
	return n


if __name__ == "__main__":
	raise SystemExit(main())
