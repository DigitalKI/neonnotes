# ADR-0016 — Area View is a continuous semantic embedding

**Status:** accepted (2026-10-27; user decision)

## Context

The Area View (ADR-0013 Phase 5) originally packed *semantic islands*: notes
were clustered by union-find over a top-k TF-IDF neighbour graph, and each
island was drawn as a circle on a square grid. Two problems surfaced with real
vaults:

- **One giant island.** The stopword list is English-only; in a mixed-language
  vault the function words of every other language survive tokenisation, and
  any positive-similarity edge unions transitively — so ~98% of notes collapsed
  into a single huge circle.
- **Grid circles read as buckets, not geography.** A subject like "geography"
  should be a *region* where "Italy" and "Japan" are nearby but distinct, and
  "Japan's food" sits just off "Japan" — sub-topics offset within the topic,
  unrelated topics far apart. Islands-on-a-grid cannot express that shape.

The user decision: keep TF-IDF similarity as the signal, but lay the notes out
as one continuous organic map, and draw **only wiki-link edges** (the radial
view's travelling light, direct between notes). Semantic relatedness shows as
proximity, never as lines.

## Decision

1. **Layout:** `AreaEmbedding` (`scripts/common/area_embedding.gd`), a pure,
   deterministic Fruchterman–Reingold relaxation over the k-NN cosine graph:
   - Connected components anchor on a deterministic grid (largest first, ties
     by name) so unrelated subjects keep separate regions.
   - Members start on a golden-angle spiral sized to their component.
   - Edges attract scaled by cosine weight; nearby nodes repel within a
     radius through a spatial hash; distant nodes never interact, so one
     region's edit cannot wander another region.
   - Fixed iteration count, linear temperature, sorted stable iteration
     orders — same input yields bit-identical positions (the `AreaLayout`
     contract; no randomness).
   - A term in ≥85% of notes is dropped from vectors entirely (the
     common-term filter), so no language's function words can glue the vault
     together.
2. **Delivery:** `TfidfBodyStore` computes index + embedding on its worker
   thread and hands the whole map to `GraphView` through
   `area_positions_cb` (`{note: Vector2}` in a fixed map frame; the camera
   fits it). A note save re-indexes the one note synchronously (~ms, so the
   focus card answers the new text immediately) and re-embeds **debounced on
   the worker** — one embed per typing burst — queued behind any in-flight
   worker; the save path never joins a worker (INV-015). Re-embeds persist
   the sidecar cache at most once per persist interval (the boot scan always
   persists); a skipped persist loses nothing because the next boot's
   stat-and-hash backfill re-reads exactly the changed notes.
3. **Edges:** wiki-links only, straight lines, the radial view's travelling
   light — no folder spine, no guide rails, no similarity web.
4. **Fallback:** while no embedding exists (before the first scan, or
   standalone/test use), the view keeps `AreaLayout`'s island grid over
   `area_neighbours_cb` as a placeholder.

## Consequences

- Editing a note shifts its own region (and at most the grid anchors), not one
  isolated island — an accepted trade for the organic shape.
- `AreaLayout` is no longer the primary area layout but stays as the
  pre-scan fallback and unit-test fixture even though the embedding now
  persists across boots.
- The scan persists a sidecar cache under `user://` (per-note mtime + content
  hash, whole-corpus fingerprint): a warm boot backfills only new or changed
  notes, an unchanged corpus reuses its cached embedding verbatim, and a
  changed corpus warm-starts the relaxation from it — so an edit shifts only
  its own neighbourhood. The cache is an accelerator, never a requirement:
  a corrupt or stale file falls back to one full scan. Nothing derived is
  ever written into the vault; the notes stay the only source of truth.
- The embedding runs entirely off the main thread (INV-015); at ~400 synthetic
  notes it measures ≈0.7 s on the worker (`scripts/dev/tfidf_bench.gd`).
  The first on-device release of the per-save variant froze typing and ANR'd
  Android: joining a ~1 s embed per autosave (and dumping the whole-corpus
  sidecar JSON per save) is why the save path is debounced, queued and
  persist-throttled today (GOT-027).

## Alternatives considered

- **UMAP / t-SNE** — more organic blobs, but heavy, and t-SNE is
  non-deterministic; rejected to keep the determinism contract.
- **PCA** — deterministic and fast, but linear: clusters overlap and the
  "regions within topics" shape disappears.
- **Keep islands, add a similarity threshold** — fixes the giant circle but
  not the "buckets, not geography" reading.
- **Full-map FR without component anchors** — clusters drift and can overlap;
  anchoring bounds the drift and keeps unrelated subjects apart.
