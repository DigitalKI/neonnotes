#!/usr/bin/env bash
# Build the NeonNotes desktop release archives (Linux + Windows).
#
#   ./tools/package_desktop.sh                 # both platforms
#   ./tools/package_desktop.sh --linux-only
#   ./tools/package_desktop.sh --windows-only --skip-export
#   ./tools/package_desktop.sh --appimage      # also build an AppImage
#
# Outputs under build/desktop/:
#   NeonNotes-<version>-linux-x86_64.tar.gz
#   NeonNotes-<version>-windows-x86_64.zip
#   NeonNotes-<version>-linux-x86_64.AppImage   (with --appimage)
#   SHA256SUMS
#
# Env overrides: GODOT_BIN, RELEASE_DATE, SOURCE_DATE_EPOCH.
# The Linux/Windows export templates must be installed in the editor.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-godot}"
BUILD="$ROOT/build/desktop"
LINUX_OUT="$BUILD/linux/NeonNotes"
WINDOWS_OUT="$BUILD/windows/NeonNotes.exe"
ICON_SIZES="16 22 24 32 48 64 128 256 512"

die() {
	echo "error: $*" >&2
	exit 1
}

DO_LINUX=1
DO_WINDOWS=1
SKIP_EXPORT=0
APPIMAGE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--linux-only) DO_WINDOWS=0 ;;
		--windows-only) DO_LINUX=0 ;;
		--skip-export) SKIP_EXPORT=1 ;;
		--appimage) APPIMAGE=1 ;;
		-h | --help)
			sed -n '2,16p' "$0"
			exit 0
			;;
		*) die "unknown argument: $1 (use --help)" ;;
	esac
	shift
done

[ "$DO_LINUX" = 1 ] || [ "$DO_WINDOWS" = 1 ] || die "nothing to build"
[ "$APPIMAGE" = 0 ] || [ "$DO_LINUX" = 1 ] || die "--appimage needs the Linux build"

VERSION="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$ROOT/project.godot" | head -n 1)"
[ -n "$VERSION" ] || die 'config/version is missing from project.godot'
RELEASE_DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"

command -v "$GODOT_BIN" >/dev/null 2>&1 || die "Godot not found (set GODOT_BIN)"
command -v zip >/dev/null 2>&1 || die "zip is required for the Windows archive"
if [ ! -f "$ROOT/assets/icons/neonnotes.ico" ]; then
	echo "==> generating icons"
	python3 "$ROOT/tools/make_icons.py"
fi

export_preset() {
	local preset="$1"
	local out="$2"
	mkdir -p "$(dirname -- "$out")"
	rm -f "$out" "${out%.exe}.pck"
	echo "==> export '$preset' -> ${out#"$ROOT/"}"
	"$GODOT_BIN" --headless --path "$ROOT" --export-release "$preset" "$out"
	[ -f "$out" ] || die "export produced no file: $out"
}

stage_linux() {
	local name="NeonNotes-$VERSION-linux-x86_64"
	local stage="$BUILD/stage/$name"
	rm -rf "$stage"
	install -d "$stage"
	install -m755 "$LINUX_OUT" "$stage/NeonNotes"
	install -m644 "$ROOT/LICENSE" "$ROOT/README.md" "$stage/"
	install -m755 "$ROOT/packaging/linux/install.sh" "$stage/install.sh"
	install -m644 "$ROOT/packaging/linux/com.neonnotes.NeonNotes.desktop" "$stage/"
	sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$RELEASE_DATE/g" \
		"$ROOT/packaging/linux/com.neonnotes.NeonNotes.metainfo.xml" \
		> "$stage/com.neonnotes.NeonNotes.metainfo.xml"
	for size in $ICON_SIZES; do
		install -Dm644 "$ROOT/assets/icons/neonnotes-$size.png" \
			"$stage/icons/hicolor/${size}x${size}/apps/neonnotes.png"
	done

	echo "==> archive: $name.tar.gz"
	if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
		tar --sort=name --owner=0 --group=0 --numeric-owner \
			--mtime="@$SOURCE_DATE_EPOCH" \
			-C "$BUILD/stage" -cf - "$name" | gzip -9n > "$BUILD/$name.tar.gz"
	else
		tar --sort=name --owner=0 --group=0 --numeric-owner \
			-C "$BUILD/stage" -cf - "$name" | gzip -9n > "$BUILD/$name.tar.gz"
	fi
}

stage_windows() {
	local name="NeonNotes-$VERSION-windows-x86_64"
	local stage="$BUILD/stage/$name"
	rm -rf "$stage"
	install -d "$stage"
	install -m644 "$WINDOWS_OUT" "$stage/NeonNotes.exe"
	install -m644 "$ROOT/LICENSE" "$ROOT/README.md" "$stage/"
	cat > "$stage/RUNNING.txt" <<'TXT'
NeonNotes for Windows
=====================

Run NeonNotes.exe. The build is portable: keep the folder together.

Notes live in %APPDATA%\Godot\app_userdata\NeonNotes\vault by default.
Use Settings > Vault to choose another folder.

This community build is not code-signed, so Windows SmartScreen may warn.
Verify the SHA-256 checksum in SHA256SUMS before running it.
TXT

	echo "==> archive: $name.zip"
	(cd "$BUILD/stage" && zip -qr9 "$BUILD/$name.zip" "$name")
}

build_appimage() {
	local name="NeonNotes-$VERSION-linux-x86_64"
	local appdir="$BUILD/appimage/NeonNotes.AppDir"
	rm -rf "$appdir"
	install -d "$appdir/usr/bin" "$appdir/usr/share/applications" "$appdir/usr/share/metainfo"
	install -m755 "$LINUX_OUT" "$appdir/usr/bin/NeonNotes"
	ln -sfn NeonNotes "$appdir/usr/bin/neonnotes"
	install -m644 "$ROOT/packaging/linux/com.neonnotes.NeonNotes.desktop" \
		"$appdir/neonnotes.desktop"
	install -m644 "$ROOT/packaging/linux/com.neonnotes.NeonNotes.desktop" \
		"$appdir/usr/share/applications/com.neonnotes.NeonNotes.desktop"
	sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$RELEASE_DATE/g" \
		"$ROOT/packaging/linux/com.neonnotes.NeonNotes.metainfo.xml" \
		> "$appdir/usr/share/metainfo/com.neonnotes.NeonNotes.metainfo.xml"
	install -m644 "$ROOT/assets/icons/neonnotes-256.png" "$appdir/neonnotes.png"
	for size in $ICON_SIZES; do
		install -Dm644 "$ROOT/assets/icons/neonnotes-$size.png" \
			"$appdir/usr/share/icons/hicolor/${size}x${size}/apps/neonnotes.png"
	done
	cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/NeonNotes" "$@"
APPRUN
	chmod +x "$appdir/AppRun"

	if ! command -v appimagetool >/dev/null 2>&1; then
		echo "warning: appimagetool not found; staged AppDir left at ${appdir#"$ROOT/"}" >&2
		return 0
	fi
	echo "==> AppImage: $name.AppImage"
	ARCH=x86_64 appimagetool "$appdir" "$BUILD/$name.AppImage"
}

write_checksums() {
	local files=()
	local f
	for f in "$BUILD"/*.tar.gz "$BUILD"/*.zip "$BUILD"/*.AppImage; do
		[ -f "$f" ] && files+=("$(basename -- "$f")")
	done
	[ "${#files[@]}" -gt 0 ] || return 0
	(cd "$BUILD" && sha256sum "${files[@]}" > SHA256SUMS)
	echo "==> checksums: build/desktop/SHA256SUMS"
}

if [ "$SKIP_EXPORT" = 1 ]; then
	[ "$DO_LINUX" = 0 ] || [ -f "$LINUX_OUT" ] || die "missing $LINUX_OUT (drop --skip-export)"
	[ "$DO_WINDOWS" = 0 ] || [ -f "$WINDOWS_OUT" ] || die "missing $WINDOWS_OUT (drop --skip-export)"
else
	[ "$DO_LINUX" = 0 ] || export_preset "Linux" "$LINUX_OUT"
	[ "$DO_WINDOWS" = 0 ] || export_preset "Windows" "$WINDOWS_OUT"
fi

if [ "$DO_LINUX" = 1 ]; then
	stage_linux
	[ "$APPIMAGE" = 0 ] || build_appimage
fi
[ "$DO_WINDOWS" = 0 ] || stage_windows
write_checksums

echo
echo "Desktop release $VERSION ready in build/desktop/:"
ls -1 "$BUILD"/*.tar.gz "$BUILD"/*.zip "$BUILD"/*.AppImage 2>/dev/null || true
