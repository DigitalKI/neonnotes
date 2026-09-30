extends Node
## Regression: sync identity is bound to the VAULT, not the device.
##  - each vault folder carries its own non-secret id (.neonnotes-id)
##  - switching vaults swaps the phrase + peers (no leakage between vaults)
##  - unpair keeps the phrase; reset words mints a new phrase AND id (fork)
##
## Disposable user:// vaults + suppressed settings writes: it can never touch a
## real vault or its settings.cfg. Wired into tests/run_tests.sh.

var _fails := 0

func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok  - " + what)
	else:
		_fails += 1
		print("  FAIL- " + what)

func _ready() -> void:
	GameManager.suppress_settings_save = true  # never persist test state

	var a := "user://per-vault-a"
	var b := "user://per-vault-b"
	_rm(a)
	_rm(b)
	DirAccess.make_dir_recursive_absolute(a)
	DirAccess.make_dir_recursive_absolute(b)

	# Vault A: identity is minted, peers recorded.
	_check(GameManager.set_vault_dir(a), "open vault A")
	var id_a := GameManager.vault_id
	var secret_a := GameManager.vault_secret
	_check(id_a != "" and secret_a != "", "vault A has an id + phrase")
	_check(FileAccess.file_exists(GameManager.vault_abs() + "/" + GameManager.VAULT_ID_FILE), "vault A id file written")
	GameManager.add_trusted("peer-a")
	GameManager.paired_peers["peer-a"] = {"name": "A", "vault_id": id_a, "ip": "10.0.0.1", "phrase": secret_a}
	GameManager.paired_vault_id = id_a
	GameManager._save_vault_identity()

	# Vault B: a different id + phrase, no peers.
	_check(GameManager.set_vault_dir(b), "open vault B")
	var id_b := GameManager.vault_id
	var secret_b := GameManager.vault_secret
	_check(id_b != "" and id_b != id_a, "vault B has its own id")
	_check(secret_b != "" and secret_b != secret_a, "vault B has its own phrase")
	_check(GameManager.trusted.is_empty() and GameManager.paired_peers.is_empty(), "vault B starts unpaired (no leakage from A)")
	_check(not GameManager.is_vault_paired(), "vault B not paired")

	# Back to A: phrase + peers come back.
	_check(GameManager.set_vault_dir(a), "reopen vault A")
	_check(GameManager.vault_id == id_a, "vault A id restored")
	_check(GameManager.vault_secret == secret_a, "vault A phrase restored")
	_check(GameManager.trusted.has("peer-a"), "vault A peers restored")
	_check(GameManager.is_vault_paired(), "vault A paired again")

	# Unpair: peers gone, phrase kept (re-pair is one entry).
	GameManager.unpair_vault()
	_check(GameManager.trusted.is_empty() and GameManager.paired_peers.is_empty(), "unpair drops peers")
	_check(GameManager.vault_secret == secret_a, "unpair keeps the phrase")
	_check(GameManager.vault_id == id_a, "unpair keeps the vault id")

	# Reset words: brand-new phrase AND id (fork).
	GameManager.reset_vault_words()
	_check(GameManager.vault_secret != secret_a, "reset mints a new phrase")
	_check(GameManager.vault_id != id_a, "reset mints a new vault id")
	var reread := GameManager.vault_id
	GameManager.load_vault_id()
	_check(GameManager.vault_id == reread, "reset id persisted to the vault folder")

	print("PER-VAULT SYNC RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _rm(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs):
		var d := DirAccess.open(abs)
		if d:
			for f in d.get_files():
				d.remove(f)
			for sub in d.get_directories():
				_rm(dir + "/" + sub)
		DirAccess.remove_absolute(abs)
