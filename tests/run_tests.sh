#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

godot --headless --path . --script tests/unit_tests.gd
NEONNOTES_SMOKE=1 godot --headless --path .