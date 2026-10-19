# ADR-0013 — Graph as a knowledge-base editor (relationship & provenance model)

**Status:** accepted (2026-10-19; user decision)

## Context

The radial graph (ADR-0005) currently visualizes *explicit* wiki-links only.
The next direction is to make the graph a second way to *work with* the same
knowledge model — navigate, edit, discover, and compose — not just render
links. The risk: if "graph relationships" become a separate, graph-only store,
the graph drifts from the Markdown source of truth and edits stop round-tripping.

## Decision

The graph is a visual interface over the same Markdown knowledge model; Markdown
notes + wiki-links remain the source of truth. A relationship is typed by
**provenance**:

- **explicit** — a real `[[wiki-link]]` in a note (the only kind that is a fact);
- **inferred** — computed by a deterministic signal, never written as a link;
- **suggested** — an inferred relationship strong enough to *offer* as an action;
- **rejected** — a suggestion the user dismissed (distinct from absence).

Editing in the graph writes canonical wiki-links back into Markdown; removing a
relationship removes the wiki-link. There is no graph-only relationship state.

Relationships are discovered by an **explainable engine**, not one opaque score:
independent signals (explicit links, lexical overlap, tag overlap, shared
neighbours, structural proximity; semantic + behavioural deferred) combined with
configurable weights, each retaining its component evidence so the UI can
explain *why* a suggestion exists.

## Layering

`KnowledgeIndex` (owned cache: notes, links, tags, titles, hierarchy, mtimes)
→ `RelationshipEngine` (explicit read side + inference signals, pure/RefCounted)
→ `GraphModel` (visible nodes/edges, layout-independent) → `GraphView`
(renderer/controller only — no file scanning or semantic analysis).

## Consequences

- Derived relationships persist in a **separate** `.neonnotes-relationships.json`
  (not the existing `.neonnotes.json` order file); it is rebuildable from the
  vault and deletable without corrupting it. Rejected suggestions are not
  persisted for now.
- The first milestone is explicit graph editing (create/remove wiki-links) with
  no inference; semantic/embedding/AI/sketch features are later and optional.
- AI is a suggestion layer only: previewable, reversible, never a silent
  mutation, never required for navigation.
- Non-goals: not Mermaid, a generic diagram editor, UML, a whiteboard, or a
  mandatory vector database.
