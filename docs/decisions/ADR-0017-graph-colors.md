# ADR-0017 — Graph folder colours are generated on the OKHSL wheel

_Status: accepted (2026-10-28). Supersedes the fixed six-colour folder palette
introduced with the shared `GraphColors` helper._

## Context

A note's colour identifies its top-level folder, and the same rule feeds both
graph layouts (radial and area), so a note keeps its colour when views or
devices switch. The original rule hashed the folder name into a **fixed
six-colour palette** (`hash % 6`):

- With six buckets, collisions are near-certain on real vaults — three
  folders already collide ~44% of the time, five folders ~62%. Two different
  sections of the map then read as one, which is worse than no colour at all.
- Growing the fixed list only postpones the problem (the birthday paradox is
  brutal: even 16 fixed buckets collide >50% of the time with 8 folders), and
  hand-picking more colours stops scaling.

## Decision

`GraphColors` **generates** the palette per vault instead of picking from a
fixed list:

1. Every top-level folder hashes to a hue on the wheel. `String.hash()`'s low
   bits cluster badly on short names (e.g. "work", "code" and "papa" all land
   within 0.0005 of each other), so the hash is diffused with the murmur3
   32-bit finalizer before it is read as a hue.
2. Folders are placed in sorted name order; when a folder's hue lands within
   `HUE_MIN_GAP` (22.5°) of an already-placed one, it steps the **golden
   angle** (137.5°) until it is far enough away — the classic
   maximally-spread sequence behind categorical colour generators. The walk
   keeps the widest-gap candidate seen, so it terminates deterministically
   even past the hue budget.
3. The colour is `Color.from_ok_hsl(hue, 0.85, 0.80)`. OKHSL is perceptually
   uniform, so every folder colour has the same perceived lightness and
   chroma: **only the hue differs**, which is what keeps a dense map legible
   on the dark themes (no folder reads brighter or duller than another). The
   constants stay in the neon family of the palette they replace.

Root notes (no top-level folder) keep the theme's `accent2` fallback.

## Properties and caps

- **Unbounded colours:** the palette has no fixed size; every folder gets its
  own hue however many there are.
- **Distinctness:** up to ~8 top-level folders every pair stays ≥22.5° apart
  (clearly different at constant lightness). Past that budget the walk is
  best-effort — new folders close in on the widest gaps left, degrading
  gradually instead of colliding outright.
- **Stability:** a folder's colour is a pure function of its name; it only
  moves when a *new* folder's hue actually collides with it (the newcomer is
  the one that steps). Colours are identical across launches, layouts and
  synced devices.
- **Cheap:** one `O(notes)` pass per map rebuild, both layouts share the
  result.

## Alternatives considered

- **More fixed colours** (12–16 hand-picked): collisions persist (birthday
  paradox) and the list stops being maintainable.
- **Ordinal golden-angle assignment** (first folder gets hue 0, second 137.5°,
  …): perfectly distinct, but adding a folder that sorts earlier rotates the
  colour of every later folder — the whole map would need relearning after a
  rename or insertion.
- **Raw hash → hue without repair:** unbounded, but two folders can land
  arbitrarily close, producing look-alike colours that are *harder* to tell
  apart than honest duplicates.

## Test map

- `tests/unit_tests.gd` `_check_graph_colors`: fallbacks, same-folder
  equality, cross-folder distinctness, determinism, order independence,
  8-folder pairwise distinctness, live-rederived collision fixture
  ("alpha"/"lima"), oversubscription (24 folders) termination.
- `scripts/dev/graph_probe.gd` §11 (radial folder vs root fallback) and §20
  (a note keeps its exact colour across the radial ⇄ area switch) — the
  user-visible contract, asserted headless on desktop.