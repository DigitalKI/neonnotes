extends Node
## Regression: an editor/MCP dev session must boot against the disposable dev
## vault, suppress settings writes and drop sync pairing — so automated runs can
## never litter or repoint the user's real vault (the bug this guards).
##
## Run via `NEONNOTES_DEV=1 ... tests/TestDevIsolation.tscn` (see run_tests.sh);
## the marker is what makes this process a dev session.

const DevSession := preload("res://scripts/common/dev_session.gd")

func _ready() -> void:
	var ok := true
	ok = ok and DevSession.is_active()
	ok = ok and GameManager.dev_session
	ok = ok and GameManager.vault_dir == DevSession.DEFAULT_VAULT
	ok = ok and GameManager.suppress_settings_save
	# No real pairing may survive into a test session.
	ok = ok and GameManager.trusted.is_empty()
	ok = ok and GameManager.paired_peers.is_empty()
	ok = ok and GameManager.paired_vault_id == ""
	ok = ok and GameManager.vault_id.begins_with("dev-")
	# The boot must not have persisted the dev vault as the user's selection.
	var cf := ConfigFile.new()
	if cf.load(GameManager.SETTINGS) == OK:
		ok = ok and String(cf.get_value("vault", "dir", "")) != DevSession.DEFAULT_VAULT
	print("DEV ISOLATION RESULT: %s" % ("OK" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
