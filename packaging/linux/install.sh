#!/usr/bin/env bash
# Install NeonNotes for the current user, or system-wide with PREFIX=/usr.
#
#   ./install.sh                 # ~/.local (no root)
#   PREFIX=/usr sudo ./install.sh
#   ./install.sh --uninstall
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APP_DIR="$PREFIX/lib/neonnotes"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share"
ICON_SIZES="16 22 24 32 48 64 128 256 512"
DESKTOP_ID="com.neonnotes.NeonNotes"

die() {
	echo "error: $*" >&2
	exit 1
}

refresh_caches() {
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database -q "$DATA_DIR/applications" || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		gtk-update-icon-cache -q -t "$DATA_DIR/icons/hicolor" 2>/dev/null || true
	fi
}

uninstall() {
	rm -f "$BIN_DIR/neonnotes"
	rm -rf "$APP_DIR"
	rm -f "$DATA_DIR/applications/$DESKTOP_ID.desktop"
	rm -f "$DATA_DIR/metainfo/$DESKTOP_ID.metainfo.xml"
	for size in $ICON_SIZES; do
		rm -f "$DATA_DIR/icons/hicolor/${size}x${size}/apps/neonnotes.png"
		rmdir --ignore-fail-on-non-empty \
			"$DATA_DIR/icons/hicolor/${size}x${size}/apps" \
			"$DATA_DIR/icons/hicolor/${size}x${size}" 2>/dev/null || true
	done
	rmdir --ignore-fail-on-non-empty \
		"$DATA_DIR/icons/hicolor" "$DATA_DIR/icons" "$DATA_DIR/metainfo" \
		"$DATA_DIR/applications" "$BIN_DIR" "$(dirname -- "$APP_DIR")" 2>/dev/null || true
	refresh_caches
	echo "Removed NeonNotes from $PREFIX"
}

case "${1:-}" in
	"") ;;
	--uninstall)
		uninstall
		exit 0
		;;
	-h | --help)
		sed -n '2,8p' "$0"
		exit 0
		;;
	*)
		die "unknown argument: $1 (use --uninstall or --help)"
		;;
esac

[ -x "$HERE/NeonNotes" ] || die "NeonNotes is missing; run this from the extracted archive"
[ -f "$HERE/$DESKTOP_ID.desktop" ] || die "desktop entry is missing from the archive"
[ -f "$HERE/$DESKTOP_ID.metainfo.xml" ] || die "AppStream metainfo is missing from the archive"

install -d "$APP_DIR" "$BIN_DIR" "$DATA_DIR/applications" "$DATA_DIR/metainfo"
install -m755 "$HERE/NeonNotes" "$APP_DIR/NeonNotes"
ln -sfn "$APP_DIR/NeonNotes" "$BIN_DIR/neonnotes"
install -m644 "$HERE/$DESKTOP_ID.desktop" "$DATA_DIR/applications/$DESKTOP_ID.desktop"
install -m644 "$HERE/$DESKTOP_ID.metainfo.xml" "$DATA_DIR/metainfo/$DESKTOP_ID.metainfo.xml"
for size in $ICON_SIZES; do
	install -Dm644 "$HERE/icons/hicolor/${size}x${size}/apps/neonnotes.png" \
		"$DATA_DIR/icons/hicolor/${size}x${size}/apps/neonnotes.png"
done
[ -f "$HERE/LICENSE" ] && install -m644 "$HERE/LICENSE" "$APP_DIR/LICENSE"

refresh_caches
echo "Installed NeonNotes to $APP_DIR"
echo "Launch it from your app menu, or run: neonnotes"
case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*) echo "note: $BIN_DIR is not on PATH; add it to use the 'neonnotes' command." ;;
esac
