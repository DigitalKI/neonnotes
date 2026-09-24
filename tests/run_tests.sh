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
run_godot_test "ALL DRAG TESTS PASSED SUCCESSFULLY!" --headless --path . tests/TestVaultTreeDrag.tscn
run_godot_test "MOBILE TREE TOUCH RESULT: OK" --headless --path . tests/ReproTreeTap.tscn
# Sync delete/move propagation over loopback (real frame protocol + tombstones).
run_godot_test "SYNC DELETE/MOVE RESULT: OK" --headless --path . tests/TestSyncDeleteMove.tscn
NEONNOTES_SMOKE=1 run_godot_test "SMOKE RESULT: OK" --headless --path .
