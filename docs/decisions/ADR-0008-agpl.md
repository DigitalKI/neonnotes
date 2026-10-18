# ADR-0008 — AGPL-3.0

**Status:** accepted (2026-10-01; switched from MIT)

## Context

The project is free and forkable, but the intended monetization is service-based
(cloud, CMS integrations, cloud AI). A permissive license lets a closed
competitor fork the client and offer a competing service without contributing
back.

## Decision

NeonNotes is licensed **AGPL-3.0**. Derivatives and anyone offering a modified
version as a network service must release their source and keep the copyright
notice. The author retains the ability to offer paid services or a separate
commercial license for those services.

## Consequences

- Bundled third-party pieces keep their own licenses (godot-mcp is MIT; fonts are
  SIL OFL).
- The `LICENSE` file is the canonical text; README links it.
- Do not relicense without an explicit project-owner decision.
