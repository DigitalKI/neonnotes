#!/usr/bin/env bash
# Build NeonNotes' 2D-only Godot Android export templates and install them into
# the project's Android build template.
#
# The Gradle Android export does not read `custom_template/*` from
# export_presets.cfg: it packages `android/build/libs/<type>/godot-lib.template_<type>.aar`.
# This script rebuilds that AAR (native lib plus the version-matched Java code)
# from the engine source and the selected build profile (`2D-V2` by default).
#
# Usage:
#   ./tools/build_android_custom.sh            # build + install the AARs
#   ./tools/build_android_custom.sh --export   # ...then export both APKs
#
# Environment overrides:
#   GODOT_SRC     engine checkout (default: ~/Projects/Godot/godot-4.7.2)
#   GODOT_BIN     editor used for --export (default: godot)
#   ANDROID_HOME  Android SDK (default: ~/tools/android-sdk)
#   JAVA_HOME     JDK 17 (default: ~/tools/jdk-17.0.20.1+1)
#   BUILD_PROFILE build profile (default: <repo>/2D-V2; use 2D-V1 for the conservative build)
#   ARCH          Android ABI (default: arm64)
#   JOBS          scons parallelism (default: 2; use 1 on memory-tight machines)
#   GRADLE_HEAP   Gradle max heap, also written to android/build/gradle.properties
#                 (default: 1500m)
#
# See docs/android-custom-build.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_SRC="${GODOT_SRC:-$HOME/Projects/Godot/godot-4.7.2}"
GODOT_BIN="${GODOT_BIN:-godot}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/tools/android-sdk}"
JAVA_HOME="${JAVA_HOME:-$HOME/tools/jdk-17.0.20.1+1}"
BUILD_PROFILE="${BUILD_PROFILE:-$ROOT/2D-V2}"
ARCH="${ARCH:-arm64}"
JOBS="${JOBS:-2}"
GRADLE_HEAP="${GRADLE_HEAP:-1500m}"

EXPORT=0
case "${1:-}" in
	"") ;;
	--export) EXPORT=1 ;;
	-h | --help)
		sed -n '2,31p' "$0"
		exit 0
		;;
	*)
		echo "Unknown argument: $1 (use --export or --help)" >&2
		exit 2
		;;
esac

die() {
	echo "error: $*" >&2
	exit 1
}

[ -f "$GODOT_SRC/SConstruct" ] || die "no Godot source at $GODOT_SRC (set GODOT_SRC)"
[ -f "$BUILD_PROFILE" ] || die "no build profile at $BUILD_PROFILE"
[ -f "$ROOT/android/build/build.gradle" ] || die \
	"Android build template is not installed in $ROOT/android/build; run Project > Install Android Build Template in the editor first"
[ -d "$ANDROID_HOME" ] || die "no Android SDK at $ANDROID_HOME"
command -v scons >/dev/null || die "scons is not installed"
command -v python3 >/dev/null || die "python3 is not installed"
if ! command -v pkg-config >/dev/null; then
	# Common local-only install (no root) used on this project's machines.
	if [ -x "$HOME/tools/bin/pkg-config" ]; then
		PATH="$HOME/tools/bin:$PATH"
		export PATH
	else
		die "pkg-config is not on PATH (Godot's scons build aborts without it)"
	fi
fi

EXPECTED_VERSION="$(cat "$ROOT/android/.build_version" 2>/dev/null || true)"
ACTUAL_VERSION="$(python3 - "$GODOT_SRC/version.py" <<'PY'
import sys

ns = {}
exec(open(sys.argv[1], encoding="utf-8").read(), ns)
print(f"{ns['major']}.{ns['minor']}.{ns['patch']}.{ns['status']}")
PY
)" || die "could not read the engine version from $GODOT_SRC/version.py"
if [ -n "$EXPECTED_VERSION" ] && [ "$EXPECTED_VERSION" != "$ACTUAL_VERSION" ]; then
	die "engine is $ACTUAL_VERSION but the installed Android template is $EXPECTED_VERSION; check out the matching tag and reinstall the template"
fi

NDK_VERSION="$(python3 - "$GODOT_SRC" <<'PY'
import re
import sys

text = open(sys.argv[1] + "/platform/android/detect.py", encoding="utf-8").read()
match = re.search(r'def get_ndk_version\(\):\s*return "([^"]+)"', text)
if not match:
    sys.exit(1)
print(match.group(1))
PY
)" || die "could not read the required NDK version from platform/android/detect.py"
export ANDROID_HOME
export JAVA_HOME
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_HOME/ndk/$NDK_VERSION}"
export PATH="$JAVA_HOME/bin:$PATH"

if [ ! -d "$ANDROID_NDK_ROOT" ]; then
	# scons installs the NDK through sdkmanager when it is missing, but only if
	# cmdline-tools are present.
	[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ] || die \
		"NDK $NDK_VERSION missing and sdkmanager not found; install it with: sdkmanager \"ndk;$NDK_VERSION\""
	echo "NDK $NDK_VERSION is missing; scons will install it via sdkmanager"
fi

if [ ! -f "$GODOT_SRC/thirdparty/swappy-frame-pacing/$ARCH/libswappy_static.a" ]; then
	echo "Installing Swappy frame pacing..."
	(cd "$GODOT_SRC" && python3 misc/scripts/install_swappy_android.py)
fi

echo "== Engine source: $GODOT_SRC"
echo "== Build profile: $BUILD_PROFILE"
echo "== Arch: $ARCH, jobs: $JOBS, NDK: $NDK_VERSION"

build_template() {
	local target="$1"
	shift
	echo "== scons target=$target"
	(cd "$GODOT_SRC" && scons \
		platform=android \
		target="$target" \
		arch="$ARCH" \
		swappy=yes \
		build_profile="$BUILD_PROFILE" \
		-j"$JOBS" \
		"$@")
}

build_template template_release production=yes
build_template template_debug

echo "== Gradle: assemble the matching AARs"
(
	cd "$GODOT_SRC/platform/android/java"
	./gradlew :lib:assembleTemplateRelease :lib:assembleTemplateDebug \
		--no-daemon \
		-Dorg.gradle.jvmargs="-Xmx$GRADLE_HEAP" \
		-Dorg.gradle.parallel=false
)

install_aar() {
	local type="$1"
	local src="$GODOT_SRC/platform/android/java/lib/build/outputs/aar/godot-lib.template_$type.aar"
	local dst="$ROOT/android/build/libs/$type/godot-lib.template_$type.aar"
	[ -f "$src" ] || die "missing $src"
	[ -f "$dst" ] || die "missing installed template $dst"
	if [ ! -f "$dst.official" ]; then
		cp -p "$dst" "$dst.official"
		echo "   backed up official AAR to $dst.official"
	fi
	cp -p "$src" "$dst"
	echo "   installed $dst ($(du -h "$dst" | cut -f1))"
}

echo "== Installing AARs into the project build template"
install_aar release
install_aar debug

# The Gradle export reads this file; keep the daemon inside the same cap.
GRADLE_PROPS="$ROOT/android/build/gradle.properties"
if [ -f "$GRADLE_PROPS" ]; then
	if grep -q '^org.gradle.jvmargs=' "$GRADLE_PROPS"; then
		sed -i "s|^org.gradle.jvmargs=.*|org.gradle.jvmargs=-Xmx$GRADLE_HEAP|" "$GRADLE_PROPS"
	else
		printf '\norg.gradle.jvmargs=-Xmx%s\n' "$GRADLE_HEAP" >>"$GRADLE_PROPS"
	fi
fi

if [ "$EXPORT" = 1 ]; then
	command -v "$GODOT_BIN" >/dev/null || die "no $GODOT_BIN on PATH (set GODOT_BIN)"
	mkdir -p "$ROOT/build"
	for apk in NeonNotes-release.apk NeonNotes-debug.apk; do
		if [ -f "$ROOT/build/$apk" ] && [ ! -f "$ROOT/build/$apk.official" ]; then
			cp -p "$ROOT/build/$apk" "$ROOT/build/$apk.official"
			echo "   backed up $apk to $apk.official"
		fi
	done
	echo "== Exporting release APK"
	(cd "$ROOT" && "$GODOT_BIN" --headless --path . --export-release "Android (Release)" build/NeonNotes-release.apk)
	echo "== Exporting debug APK"
	(cd "$ROOT" && "$GODOT_BIN" --headless --path . --export-debug "Android" build/NeonNotes-debug.apk)
	ls -lh "$ROOT/build/NeonNotes-release.apk" "$ROOT/build/NeonNotes-debug.apk"
else
	echo "== Done. Export with:"
	echo "   godot --headless --path . --export-release \"Android (Release)\" build/NeonNotes-release.apk"
	echo "   godot --headless --path . --export-debug \"Android\" build/NeonNotes-debug.apk"
fi
