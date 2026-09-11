#!/usr/bin/env bash
# Remote-debug NeonNotes on your phone over USB.
# 1. Enable USB debugging on the phone and connect it.
# 2. Run this script (keeps the editor debugger listening via `godot -e`).
# 3. Launch NeonNotes on the phone — it will connect to the editor debugger.
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
adb reverse tcp:6007 tcp:6007
echo "USB reverse tunnel: phone:6007 -> PC:6007"
echo "Starting editor (debugger listens while the editor is open)..."
godot --path "$PROJECT_DIR" --editor
