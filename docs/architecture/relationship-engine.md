# RelationshipEngine & KnowledgeIndex — design

_Status: complete (Phase 0 of the graph-as-editor plan, ADR-0013)_

Phase 0 is landed: the relationship/provenance model is defined and the layered
read model is wired end-to-end with no visible behavior change — `GameManager`
owns a `KnowledgeIndex` snapshot (`index` + `refresh_index()`, rebuilt on
scan/write/move); `RelationshipEngine` carries the read side
(`explicit_relationships`) and all traversal (`neighbours`, `compute_levels`,
`build_neighbourhood`); `GraphModel` is a pure data shape; `GraphView` serves
resolved links and the level map from the shared index/engine, and
`WikiLinks.graph` delegates to `explicit_relationships` + the index spine.
`WikiLinks` and `GameManager` keep their public APIs. `tests/run_tests.sh` is
green throughout. Phase 1 (explicit graph editing) and Phase 2 (inference) are
next; the raw fields still live on `GameManager` and move into `KnowledgeIndex`
as an incremental cleanup (see the migration map).

Phase 0 turns the graph from a renderer over `GameManager`'s raw index into a
layered read model shared by the graph editor, search, backlinks, and (later)
inference. It is a behavior-preserving refactor: no visible output changes and
`tests/run_tests.sh` stays green through it.

## Layering

```
KnowledgeIndex          owned cache: raw note/title/tag/link data + derived structure
      │
      ▼
RelationshipEngine      pure computation (no GameManager, no file I/O)
      │
      ├── explicit relationships (wiki-links)
      ├── traversal / graph neighbourhood
      └── (Phase 2) inferred & suggested relationships
      ▼
GraphModel              pure data shape (nodes, edges, levels, titles)
      ▼
GraphView               renderer/controller only
```

Folder hierarchy is **structure, not a relationship**. `KnowledgeIndex` owns
`parent_of`/`children_of` (the folder-as-note spine, INV-011); it is drawn as
`tree` edges and changes only via folder moves, never through graph editing.
The relationship model (`KnowledgeRelationship`) covers *semantic/editorial*
links only: `wiki_link` now, `inferred`/`suggested` later.

## KnowledgeIndex

A `RefCounted` snapshot `GameManager` builds and owns. Raw data plus the
deterministic derivations, computed once on build and invalidated on
scan/write.

```gdscript
class_name KnowledgeIndex
extends RefCounted

# raw — filled by GameManager's scan/index/async-metadata pass
var notes: Array[String] = []     # vault-relative paths, sorted
var titles: Dictionary = {}       # rel -> front-matter title ("" = filename)
var tags: Dictionary = {}         # rel -> Array[String]
var links: Dictionary = {}        # rel -> Array[String] RAW outbound [[target]]s

# derived structure — pure functions of `notes`, computed on build
var parent_of: Dictionary = {}    # rel -> companion note rel ("" = none)
var children_of: Dictionary = {}  # companion rel -> Array[String] children
var resolve_full: Dictionary = {} # lowercase full-path -> rel
var resolve_base: Dictionary = {} # lowercase basename -> rel

func build() -> void                  # recompute the derived fields from `notes`
func resolved_links() -> Dictionary   # {src: [resolved rel]} — replaces GraphView._resolved_links
```

`links` stays RAW (as `GameManager.links` is today); resolution is not stored
raw-and-resolved in parallel. `resolved_links()` is the cached derivation that
collapses today's duplicated `WikiLinks.resolve_maps` + `GraphView._resolved_links`.

## RelationshipEngine

Pure `RefCounted`; every function takes plain data (an index or slices of it),
so it is unit-testable under `godot --script` like `GraphModel`/`PathRemap` are.

### Explicit read side (Phase 0)

```gdscript
class_name RelationshipEngine
extends RefCounted

# resolution (from WikiLinks)
static func resolve_maps(notes: Array[String]) -> Array
static func resolve(target: String, notes: Array[String]) -> String
static func resolve_with(target: String, maps: Array) -> String

# explicit relationships (from WikiLinks.graph + GraphModel._add_edges)
static func explicit_relationships(notes, links: Dictionary, maps: Array) -> Array[KnowledgeRelationship]

# traversal / neighbourhood (from GraphModel.neighbours/compute_levels/build)
static func build_neighbourhood(center: String, levels: int, notes: Array[String],
		resolved_links: Dictionary, titles: Dictionary, max_nodes := 400) -> GraphModel

# backlinks & linking (from WikiLinks.backlinks + GameManager)
static func backlinks(target: String, notes: Array[String], links: Dictionary) -> Array[String]
static func notes_linking_to(prefix: String, notes: Array[String], links: Dictionary) -> Array[String]

# facets (from GameManager)
static func all_tags(tags: Dictionary) -> Array[String]
static func inbox_notes(notes: Array[String]) -> Array[String]
static func note_title(rel: String, titles: Dictionary) -> String
```

`build_neighbourhood` consumes `KnowledgeIndex.parent_of`/`children_of` for the
level walk (one level = one folder move or one link hop — the existing rule)
and `explicit_relationships` for the link edges; it emits a filled `GraphModel`.

### Inference (Phase 2, not Phase 0)

```gdscript
static func infer(notes, links: Dictionary, tags: Dictionary, titles: Dictionary,
		options: Dictionary = {}) -> Array[KnowledgeRelationship]
```

Deterministic signals (tag overlap, lexical overlap, shared neighbours,
structural proximity) with configurable weights and retained evidence; no
auto-mutation. Semantic/embedding/behavioural signals are later and optional.

## Relationship data shapes

```gdscript
class_name KnowledgeRelationship
extends RefCounted

var source: String = ""                 # vault-relative path
var target: String = ""                 # vault-relative path (RESOLVED)
var kind: String = ""                   # "wiki_link" now; signal kinds in Phase 2
var provenance: String = ""             # "explicit" | "inferred" | "suggested" | "rejected"
var score: float = 0.0
var evidence: Array[Dictionary] = []            # [{"kind","value","weight"}]
var source_locations: Array[Dictionary] = []    # reserved empty until Phase 4
```

`Evidence` and `Suggestion` follow the proposal §13 shapes unchanged:

```gdscript
# evidence entry
{"kind": "shared_tag", "value": "physics", "weight": 0.25}
# suggestion
{"source": "physics.md", "target": "relativity.md", "score": 0.87, "evidence": [...], "state": "pending"}
```

`source_locations` stays empty in Phase 0 — populating it needs a
position-returning variant of `GameManager.extract_wiki_links()`, which is
Phase 4 (candidate-phrase placement + edge inspection).

## Key decisions

1. **Centralize derivations in `KnowledgeIndex`.** Hierarchy + resolve maps are
   computed once on build, not per query; this absorbs the ad-hoc caching
   `GraphView`/`GraphDigest` do today.
2. **Folder hierarchy is structure, not a relationship.** `tree` edges come from
   `KnowledgeIndex.parent_of`/`children_of` and change only via `VaultMove`
   (INV-011); they are never created/removed through graph editing. The
   relationship model has no `"tree"` kind.
3. **All traversal lives in `RelationshipEngine`.** `GraphModel` is a pure data
   shape — it computes nothing; `build_neighbourhood` fills it.
4. **`source_locations` is reserved empty until Phase 4.**

## Migration map

_(done)_ marks rows already landed; the rest are planned.

| Current symbol | New home |
|---|---|
| `GameManager.notes/titles/tags/links` | `KnowledgeIndex` fields |
| `GameManager.scan_*` / `_index_note_metadata` / `_meta_for` | `KnowledgeIndex.build` (GameManager keeps the async drip + `metadata_ready`) |
| `WikiLinks.resolve_maps/resolve/resolve_with` | `RelationshipEngine` _(done)_ |
| `WikiLinks.backlinks` | `RelationshipEngine.backlinks` _(done)_ |
| `WikiLinks.graph` | `RelationshipEngine.explicit_relationships` _(done)_ |
| `GraphModel._hierarchy` | `KnowledgeIndex` build (parent_of/children_of) _(done)_ |
| `GraphModel.neighbours/compute_levels/build/_add_edges` | `RelationshipEngine` (build_neighbourhood + explicit_relationships) _(done)_ |
| `GameManager.all_tags/inbox_notes/note_title/notes_linking_to` | `RelationshipEngine` _(done)_ |
| `GraphView._resolved_links/_rebuild_resolve_maps` | deleted → `KnowledgeIndex.resolved_links()` _(done)_ |
| `GraphDigest` reads of `GameManager.links/tags/notes` | `RelationshipEngine` + `KnowledgeIndex` (derived reads done via the engine; raw reads stay on `GameManager` until the raw-field move above) |

`WikiLinks` shrinks to a thin alias or is deleted; `GameManager.extract_wiki_links()`
+ `wiki_link_regex()` remain the single parser (they already own the canonical
regex and the escape rule).

## What GraphModel becomes

`GraphModel` keeps its data fields (`center`, `nodes`, `level_of`, `edges`,
`titles`) and `node_label()`. Its static traversal/build/edge functions move to
`RelationshipEngine`; `edges` carries a `kind` of `"tree"` (from structure) or
`"wiki_link"` / signal kinds (from relationships) so the renderer can tint them
differently without re-deriving provenance.

## Lenses, layouts & filtering (Phase 5)

Every visualization is a projection of the same `KnowledgeIndex` +
`RelationshipEngine` — no view owns a private data model. Three pure contracts
make views swappable and transitionable:

```gdscript
# Layout strategy: where every visible note sits in the viewport. Returns a
# Dictionary keyed by vault-relative note path. Each strategy may also declare
# an edge style (chord / straight / folder-spine).
func layout(model: GraphModel, viewport: Rect2) -> Dictionary   # {note_path: Vector2}

# Filter: keep or drop a note for the current lens.
func keep(note: String, index: KnowledgeIndex, query: Dictionary) -> bool

# Facet: the bucket(s) a note belongs to for column/area grouping.
func bucket(note: String, index: KnowledgeIndex, facet: String) -> Array[String]
```

- **Radial** (current) — concentric sectors, folder spine.
- **Column** — nodes bucketed into vertical columns by a facet (tag, date,
  length/size); links are straight paths across columns. Tag is multi-valued
  and date/size single-valued. A multi-tag note renders as one **primary** node
  in its home column plus **ghost replicas** in each other tag column, drawn
  dimmed below a baseline that separates real nodes from ghosts; hovering or
  selecting the node dims the rest so its replicas stand out.
- **Area / island** — related nodes grouped into contiguous regions by a
  selectable facet: an explicit cluster/suggestion (Phase 3), a shared tag, or a
  shared date.
- **Circle** — nodes on one circle, links drawn as chords/arcs.

**Transitions** are position tweens keyed by note path: switching a lens tweens
each node from its old `Vector2` to the new one and fades nodes that exist in
only one of the two. Node identity is the note path, so this is independent of
any layout's placement math.

**Live filtering** composes the tag index (instant) or the search worker
(debounced) into a `keep()` predicate, then either dims non-matches
(render-only) or hides them and re-runs `layout()` on the subset (bounded by
`MAX_NODES`).

**Bulk move.** Multi-select + move-into-target reuses the same `VaultMove.move_path()`
command as the tree; moving into a leaf auto-converts it into a folder +
companion note (the tree's drag/drop already does this — the graph Move dialog
does not yet, and should be unified). Self-nesting and Inbox-target guards come
from the existing move machinery.
