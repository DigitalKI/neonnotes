#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Bound every Godot invocation so a failed test cannot leave a runaway process.
# Keep the limits generous enough for slower CI and Android-imported projects.
run_godot() {
	timeout --foreground "${TEST_TIMEOUT_SECONDS:-60}s" godot "$@"
}

run_godot --headless --path . --script tests/unit_tests.gd
run_godot --headless --path . tests/TestVaultTreeDrag.tscn
timeout --foreground "${TEST_TIMEOUT_SECONDS:-60}s" env NEONNOTES_SMOKE=1 godot --headless --path .