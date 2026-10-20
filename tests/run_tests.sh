#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Run one Godot test and decide pass/fail from its own PASS marker rather than
# its exit code. Godot 4.7 aborts during native teardown on this project
# ("double free or corruption"), so a perfectly good test can exit 134 *after*
# printing its result — a raw exit-code check would abort the whole suite and
# silently skip every later test. A missing marker (a real crash before the
# result line) still fails the suite.
#
# Usage: run_godot_test "<marker>" <godot args...>
run_godot_test() {
	local marker="$1"
	shift
	local log
	log="$(mktemp)"
	local code=0
	set +e
	timeout --foreground "${TEST_TIMEOUT_SECONDS:-60}s" godot "$@" >"$log" 2>&1
	code=$?
	set -e
	cat "$log"
	if grep -qF -- "$marker" "$log"; then
		rm -f "$log"
		return 0
	fi
	echo "TEST FAILED: '$marker' not found (godot exit $code)" >&2
	rm -f "$log"
	return 1
}

run_godot_test "UNIT RESULT: OK" --headless --path . --script tests/unit_tests.gd
run_godot_test "SEARCH WORKER RESULT: OK" --headless --path . tests/TestSearchWorker.tscn
run_godot_test "ALL DRAG TESTS PASSED SUCCESSFULLY!" --headless --path . tests/TestVaultTreeDrag.tscn
# Inbox + capture: pinned/badged Inbox folder, text/link/image captures land
# as ordinary markdown (Inbox is a plain vault folder, so sync ships it).
run_godot_test "CAPTURE RESULT: OK" --headless --path . tests/TestCapture.tscn
# Share-sheet intake: a received link/image/file/text payload lands in Inbox
# through Capture (plugin-free routing, so it runs off-platform).
run_godot_test "SHARE INTAKE RESULT: OK" --headless --path . tests/TestShareIntake.tscn
# Trash: recoverable deletes, dot-hidden, sync-excluded, collision restore, purge.
run_godot_test "TRASH RESULT: OK" --headless --path . tests/TestTrash.tscn
# Move page: relocate a note from the ⋮ menu (stays open) and the graph circle
# menu (returns + re-focuses), rewriting wiki-links and guarding self-nesting.
run_godot_test "MOVE RESULT: OK" --headless --path . tests/TestMoveDialog.tscn
# Dev/MCP session isolation: NEONNOTES_DEV=1 must redirect the boot to the
# disposable dev vault and never persist it (keeps agent runs off the real vault).
NEONNOTES_DEV=1 run_godot_test "DEV ISOLATION RESULT: OK" --headless --path . tests/TestDevIsolation.tscn
# Metadata index cache: a warm boot rebuilds titles/tags/links from disk (stat
# check) instead of re-reading every note; changes/moves invalidate correctly.
run_godot_test "META CACHE RESULT: OK" --headless --path . tests/TestMetaCache.tscn
# ⋮ Undo/Redo: rows are present only while editing, grey out when the history
# cannot move, and the history is cleared on note switch (never cross notes).
run_godot_test "UNDO REDO RESULT: OK" --headless --path . tests/TestUndoRedo.tscn
run_godot_test "REVEAL RESULT: OK" --headless --path . tests/TestTreeReveal.tscn
# Preview horizontal fit: an open note must not widen the shell past the screen
# margins (a missing image embed's long file name used to do exactly that).
run_godot_test "PREVIEW FIT RESULT: OK" --headless --path . tests/TestPreviewFit.tscn
# Interactive preview blocks: task checkboxes write their tick to the Markdown
# file immediately (through the preview title-line offset), and separators draw.
run_godot_test "PREVIEW TASKS RESULT: OK" --headless --path . tests/TestPreviewTasks.tscn
# Unresolved wikilinks open the resolve page (suggestions + explicit create)
# instead of silently creating a note; #tag links filter without creating.
run_godot_test "LINK RESOLVE RESULT: OK" --headless --path . tests/TestLinkResolve.tscn
run_godot_test "MOBILE TREE TOUCH RESULT: OK" --headless --path . tests/ReproTreeTap.tscn
# Mobile selection overlay: select-all action, magnifier placement, proportional
# edge auto-scroll (overlay is otherwise Android-only).
run_godot_test "SELECTION RESULT: OK" --headless --path . tests/TestSelectionOverlay.tscn
# Graph focus card: digest extraction/cache, card rendering, form-factor layout.
run_godot_test "CARD RESULT: OK" --headless --path . tests/TestGraphCard.tscn
# Graph dock (desktop right panel: follow-the-note, tap actions, remembered
# width, expand to the full view) + the mobile screen-edge swipes.
run_godot_test "GRAPH DOCK RESULT: OK" --headless --path . tests/TestGraphDock.tscn
# Tree → graph follow: a tree click in another branch (or another page of the
# same scope) must move the dock's selection, not leave the old scope frozen.
run_godot_test "GRAPH TREE SYNC RESULT: OK" --headless --path . tests/TestGraphTreeSync.tscn
# Tree drag → graph: a drop must rebuild the map, and when it carries the open
# note (including a folder-note companion) the dock must follow it.
run_godot_test "GRAPH TREE DRAG RESULT: OK" --headless --path . tests/TestGraphTreeDrag.tscn
# Graph probe: tap/focus/menu, root hub, routes, adaptive layout spacing and the
# collision-aware label pass (no overlapping boxes, hovered drawn last).
run_godot_test "PROBE RESULT: OK" --headless --path . scripts/dev/GraphProbe.tscn
# Sync delete/move propagation over loopback (real frame protocol + tombstones).
run_godot_test "SYNC DELETE/MOVE RESULT: OK" --headless --path . tests/TestSyncDeleteMove.tscn
# Sync identity is per vault (in-folder id + device-local phrase); switching
# vaults swaps identity, unpair keeps the phrase, reset words forks.
run_godot_test "PER-VAULT SYNC RESULT: OK" --headless --path . tests/TestPerVaultSync.tscn
# Backup/import: zip round-trip, zip-slip rejection, clear-vault identity
# preservation, and plain Markdown import (media excluded, title injected).
NEONNOTES_DEV=1 run_godot_test "BACKUP IMPORT RESULT: OK" --headless --path . tests/TestBackupImport.tscn
NEONNOTES_SMOKE=1 run_godot_test "SMOKE RESULT: OK" --headless --path .
