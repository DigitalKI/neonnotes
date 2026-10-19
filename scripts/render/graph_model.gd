class_name GraphModel
extends RefCounted

# Preloaded (not the class_name global) so GraphModel still resolves when run
# via `godot --script`; NoteMetadata is pure (no GameManager/WikiLinks), keeping
# this class dependency-light.
const _NoteMeta := preload("res://scripts/common/note_metadata.gd")
## Renderer-agnostic graph neighbourhood: which notes are shown, how far from
## the centre, and how they connect. Knows nothing about drawing, so the view
## can be replaced later (a synthwave-style scene instead of today's canvas)
## without touching the semantics.
##
## Pure data shape (ADR-0013): it computes nothing. `RelationshipEngine` fills
## it via `build_neighbourhood`; the renderer (`GraphView`) reads it. Level
## semantics — ONE level per change, and the budget is shared by folder movement
## and direct links — live in `RelationshipEngine.compute_levels`.

var center := ""
var nodes: Array[String] = []        # centre first, then discovery order
var level_of := {}                   # note -> distance from the centre
var edges: Array[Dictionary] = []    # {"from","to","kind"}: "tree" | "direct"
var titles := {}                     # note -> front-matter title ("" = file name)

## Front-matter title, falling back to the file name — labels never show paths.
func node_label(note: String) -> String:
	return _NoteMeta.title_or_stem(String(titles.get(note, "")), note)
