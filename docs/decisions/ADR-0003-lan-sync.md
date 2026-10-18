# ADR-0003 — LAN-only sync, per-vault identity, no cloud

**Status:** accepted (2026-09-30; sync predates this record)

## Context

The app needs multi-device sync without a server, account, or vendor lock-in.
Users may keep several independent vaults on the same device.

## Decision

Sync runs only on the local network: UDP 47770 for discovery, TCP 47771 for
transfers. Identity is bound to the **vault**, not the device: a non-secret
`.neonnotes-id` lives in the vault (never synced), while the eight-word pairing
phrase and trusted peers are device-local in `settings.cfg [sync] vaults`,
keyed by vault id. Pairs reconnect automatically; only missing payloads move.
There is no cloud relay and no account.

## Consequences

- Pairing vault A never causes vault B to sync.
- `.neonnotes-id` must be rejected by `_valid_sync_path`.
- Sync state is per vault and keyed by vault id, so it survives a vault move.
- LAN traffic is unencrypted for now; the phrase itself is never sent (nonce
  proof). Treat sync as trusted-network-only.
