#!/usr/bin/env bash
# Build the tiny AAR that carries MarkdownOpenActivity.
#
# The committed AARs under bin/ are what the export uses; this script exists so
# a maintainer can rebuild them after editing the Java source. It needs a JDK
# 17+ and an Android SDK platform android.jar. Set ANDROID_JAR to override the
# detected one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

JAVAC="${JAVAC:-javac}"
JAR="${JAR:-jar}"

if [[ -z "${ANDROID_JAR:-}" ]]; then
	for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${HOME}/Android/Sdk" "${HOME}/Projects/Godot/.android-tools/android-sdk"; do
		if [[ -n "$sdk" && -f "$sdk/platforms/android-36/android.jar" ]]; then
			ANDROID_JAR="$sdk/platforms/android-36/android.jar"
			break
		fi
	done
fi

if [[ -z "${ANDROID_JAR:-}" || ! -f "$ANDROID_JAR" ]]; then
	echo "error: android.jar not found. Set ANDROID_JAR=/path/to/android-sdk/platforms/android-36/android.jar" >&2
	exit 1
fi

rm -rf build
mkdir -p build/classes build/aar bin/debug bin/release

# shellcheck disable=SC2046
"$JAVAC" -source 17 -target 17 -Xlint:-options \
	-classpath "$ANDROID_JAR" \
	-d build/classes \
	$(find android/src -name '*.java')

"$JAR" cf build/classes.jar -C build/classes .
cp android/AndroidManifest.xml build/aar/AndroidManifest.xml
cp build/classes.jar build/aar/classes.jar
(cd build/aar && "$JAR" cf ../MarkdownOpen-debug.aar .)

cp build/MarkdownOpen-debug.aar bin/debug/MarkdownOpen-debug.aar
cp build/MarkdownOpen-debug.aar bin/release/MarkdownOpen-release.aar
echo "Built bin/debug/MarkdownOpen-debug.aar and bin/release/MarkdownOpen-release.aar"
