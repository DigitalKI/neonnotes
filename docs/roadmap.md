# NeonNotes — Roadmap

_Last updated: 2026-10-18_

Direction and open work only. Finished items are deleted (git is the history).
Pending decisions state the question and the current recommendation.

## Goal

Stable v3: the desktop and Android app are reliable, and sync is verified
phone ↔ PC over the local network.

## Now

## Next

- **Sync re-verification** — LAN sync is already verified phone ↔ PC; re-run that
  check after any protocol/tombstone/manifest change.
- **Backup/import on-device verification** — the SAF save/open paths compile and
  are unit-tested, but the Android system pickers have only been reviewed from
  the docs; verify save-to-Downloads/Drive and import-from-Files on a device.
- **Obsidian/Anytype conversion** — import currently copies plain `.md` only
  (media skipped, no syntax conversion). Add a normalization profile for
  `![[image]]` embeds, heading/block anchors, aliases, inline tags, and multiline
  front-matter tags.
- **Backup automation** — manual backup + restore are built; consider
  pre-destructive snapshots, retention, and optional encryption.
- **Attachments** (proposed, not built): non-image shares (PDF, video, audio)
  are refused. Supporting them means importing bytes into the vault (e.g.
  `vault/files/`), rendering a link/placeholder, and syncing the bytes.
- **Share-to end-to-end** — the intake is wired and the debug APK packages the
  plugin, but a real browser/Photos share has not been observed end-to-end.
  iOS only gains "Open With"; a share-sheet entry needs a Share Extension.
- **Android Open-with end-to-end** — the always-enabled `ACTION_VIEW` bridge is
  packaged and its merged manifest has been inspected, but opening a `.md` from
  a real file manager has not been observed on-device. Verify the chooser entry,
  cold and warm starts, the `content://` copy, and the Inbox import.
- **Selection overlay** — confirm the magnifier feel and edge auto-scroll on a
  real device.
- **Parser block cache** — the highlighter runs a full `parse()` per text
  revision. The full highlight path is ~98 ms for 2,064 lines (the parse alone
  is ~7 ms; painting/shaping dominates). Cache per-block results by content
  hash.
- **Incremental/worker vault scan** — `GameManager.scan_notes()` re-reads the
  whole vault on the main thread (launch, vault switch, move, sync); target an
  incremental or worker scan.
- **Graph layout on a worker** — radial layout (~80 ms) and level BFS (~30 ms)
  hitch the first overview build at ~2,000 visible nodes. If adaptive radial
  spacing is still not enough, a one-time force relaxation after the radial pass
  (worker, then freeze) is the next option; no runtime physics.
- **Graph scale** — `GraphModel.MAX_NODES` (400) is a stop-gap; aggregation is
  deferred. MultiMesh markers are already in place; the remaining work is
  deciding how oversized clusters are summarized.
- **MP4/social-video export** — no MP4 MovieWriter in this build; the AVI path
  segfaults headless. Needs bundled FFmpeg or a GDExtension.
- **Sync hardening** — content hashes, conflict detection, cryptographic
  pairing, encrypted transport.
- **APK hygiene** — `include_filter="*.md"` currently ships `README.md`,
  `AGENTS.md`, and this context kit; only `docs/help.md` is needed at runtime.

### Graph as a knowledge-base editor

_Replaces the former "Graph-first (G1–G4)" bullet. Rationale: ADR-0013._

The graph becomes an interactive **editor and analysis surface** over the same
Markdown knowledge model — never a second source of truth. Relationships are
typed by provenance (explicit / inferred / suggested / rejected) and discovered
by an explainable signal engine. Phased, in `Next` (not `Now`):

- **Phase 0 — architecture prep**: define the relationship/provenance model
  without changing visible behavior; add tests for identity and provenance.
- **Phase 1 — explicit graph editing (first milestone)**: select two nodes,
  create/remove an explicit relationship that writes a canonical `[[wiki-link]]`
  into Markdown; backlinks reflect it; no graph-only state; no inference yet.
  Multi-select bulk move: move N nodes into a target node; moving into a leaf
  auto-converts it into a folder + companion note (unify with the tree's
  drag/drop, which already does this — the current Move dialog does not).
- **Phase 2 — relationship engine**: deterministic signals (tags, lexical
  overlap, shared neighbours, structural proximity) with structured evidence,
  explainable scores and configurable weights; no auto-mutation.
- **Phase 3 — suggestions & gaps**: render inferred edges differently; inspect
  evidence; accept (→ wiki-link) / reject; suppress duplicates.
- **Phase 4 — document link placement**: candidate-phrase detection, manual
  apply, optional auto placement only with confirmation (never silent rewrite);
  plus doc→graph ("Add to graph…" on selected text).
- **Phase 5 — graph lenses & layouts**: knowledge (default), similarity, gaps,
  clusters, orphans, path/connection finder, focus/expand/filter, and
  alternative layouts with animated transitions.
- **Phase 6+ (optional/future)**: embeddings (optional, cacheable), explainable
  AI suggestions, sketch-to-graph.

**Layouts, facets, filtering.** Every view is a *projection* of the same
`KnowledgeIndex`/`RelationshipEngine` — a pure `note → position` layout strategy
plus a per-layout edge style — so switching views tweens positions keyed by the
stable note path instead of rebuilding. Views: **radial** (current, folder
spine), **column** (nodes bucketed into vertical columns by a facet — tag, date,
length/size; links are straight paths across columns), **area/island** (related
nodes grouped into contiguous regions by a selectable facet — explicit
cluster/suggestion, shared tag, or date), **circle** (nodes on one circle, links
drawn as chords). Facet grouping is single- or multi-valued by parameter: tag is
multi-valued (one primary node plus dimmed ghost replicas in its other tag
columns); date/size are single-valued. Live filtering is a `note → keep(bool)`
predicate fed by the tag index + search worker, with two modes: dim non-matches
(render-only) or hide + re-layout the subset. Editing (bulk move, link
create/remove) works in every layout through the same commands; mobile uses
long-press + action-sheet triggers instead of desktop drag.

Persistence: derived relationships live in a separate
`.neonnotes-relationships.json`, rebuildable from the vault and deletable
without corruption; rejected-suggestion state is not persisted for now.
`KnowledgeIndex → RelationshipEngine → GraphModel → GraphView` is the
canonical layering (`GraphView` stays renderer/controller only).

Non-goals: not Mermaid, a generic diagram editor, UML, a whiteboard, or a
mandatory vector database. Neon City (the eventual 3D skin) remains a later
renderer option; 2D renderer improvements (edge-type distinction, confidence
encoding, edge selection, cluster boundaries, minimap, focus mode) come first.

## Known bugs / risks

- Drag inside-move drop zones still want a visual confirmation on-device.
- Companion-note collisions (`name-2.md`) after sync merges need watching.
- CRT overlay GPU cost measured ~15–16% on an AMD 820M; don't claim a GPU win
  without a fresh measurement.
- Sync transport is unencrypted; trusted-LAN only.
- Restored files get restore-time mtimes (`ZIPPacker` stores no per-file times),
  so the first sync after a restore treats them as new writes.
- Backup reads each file whole into memory (`ZIPPacker` has no streaming API);
  a vault with very large media can spike memory on a phone.
- Android share target needs one rendered frame after install; a dozing/locked
  phone never enables it.
- Cold boot still scans on the main thread; the metadata cache only helps warm
  boots.

## Perf watch

Baselines are device/version dependent; re-measure with the benches.

- Boot (SM-A165M, 2026-09): ≈2.9 s release / ≈4.7 s debug to first note.
- Metadata cache (1,089 notes, warm): `[boot] metadata` ≈18 ms; shell ready
  ≈108 ms. Cold run unchanged.
- Graph: ≈6–7 ms/frame at 1,000–4,000 nodes; ≈220–275 draw calls.
- Graph labels: a full placement pass is ≈7 ms at ~1,000 visible keys (headless
  CPU); a pure pan translates the cached boxes instead of re-placing (<1 ms).
- Parser: `MarkdownParser.parse()` ≈7 ms / 2,064 lines; full highlight path
  ≈98 ms (rebuild ≈79 ms).
- Scan: ≈84 ms / 1,000 notes full-file on desktop.

Commands: `NEONNOTES_BOOT_DEBUG=1 godot --path .`,
`godot --headless --path . --script scripts/dev/bench_scan.gd`,
`NEONNOTES_DEV=1 godot --path . scenes/dev/GraphBench.tscn`.
