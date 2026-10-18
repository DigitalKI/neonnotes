# ADR-0006 — Dev/MCP isolation is explicit opt-in

**Status:** accepted (2026-09-30; revised after an incident)

## Context

Automated UI runs and MCP probes must never create notes in, or repoint, the
user's real vault or announce the real sync identity on the LAN. An earlier
heuristic ("editor binary with a window") hijacked normal editor runs, opening
the disposable vault and killing sync.

## Decision

Isolation happens only when `NEONNOTES_DEV=1` (the MCP `play_scene` tool sets it)
or `NEONNOTES_VAULT=<path>` is present. In that case `GameManager` redirects to
`user://neonnotes-dev`, sets `suppress_settings_save`, and clears sync pairing.
There is **no** editor/debugger/desktop auto-detection. A normal Play/F5,
`godot --path .`, and the shipped app keep the real vault and real sync identity.

## Consequences

- Every automated launch must set one of the env vars.
- Test harnesses that use a fixture vault set `suppress_settings_save`; sync
  startup refuses to run in that state.
- The policy lives in dependency-free `scripts/common/dev_session.gd` so
  `--script` harnesses can preload it.
