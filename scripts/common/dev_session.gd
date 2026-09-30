extends RefCounted
## Explicit agent/test-session detection — owns nothing and depends on nothing,
## so headless `--script` harnesses can preload it (a preload of GameManager.gd
## would drag in SyncService, which names the GameManager autoload and cannot
## compile without it).
##
## A dev session is ONLY ever requested explicitly:
##   * `NEONNOTES_DEV=1`      — set by the godot-mcp `play_scene` tool so agent
##                              UI testing is isolated from the real vault.
##   * `NEONNOTES_VAULT=<path>` — run against an explicit scratch vault.
##
## There is deliberately NO heuristic on "editor"/debugger/desktop launches: a
## developer's own Play/F5/`godot --path .` run and the shipped app must keep the
## real vault and real sync identity. (An earlier heuristic did exactly that and
## hijacked normal desktop runs — the vault opened as `neonnotes-dev` and sync
## pairing was dropped.)
##
## GameManager redirects a dev session to DEFAULT_VAULT with settings writes
## suppressed, so agent testing can never create notes in, or repoint, the
## user's real vault.

const DEFAULT_VAULT := "user://neonnotes-dev"
const ENV_VAULT := "NEONNOTES_VAULT"
const ENV_DEV := "NEONNOTES_DEV"

static func is_active() -> bool:
	if OS.get_environment(ENV_VAULT) != "":
		return true
	return OS.get_environment(ENV_DEV) == "1"
