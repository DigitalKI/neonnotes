# ADR-0005 — Radial hierarchy graph, not force-directed

**Status:** accepted (2026-09-20; user decision)

## Context

The graph could use a force-directed layout (Obsidian/d3 style) or a
deterministic radial hierarchy. Force layouts look organic but are
non-deterministic, expensive, and obscure the folder structure that the vault
already has. Links route along the hierarchy with a travelling light.

## Decision

The map is a radial hierarchy: folders are hubs, children sit on angular
sectors, and links are routed along the folder spine with a directional light.
Layout is computed once per structure change, not simulated every frame. The
user explicitly chose this over force-directed.

## Consequences

- Positions are stable, testable, and cheap to render (`_bg` MultiMesh nodes,
  batched edge geometry).
- Crowded folders need adaptive radii and label collision handling (roadmap),
  not physics.
- A future 3D "Neon City" skin should reuse the same model/semantics.
