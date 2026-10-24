# ADR-0014 — Custom 2D-only Godot Android engine

**Status:** accepted (2026-10-20)

## Context

The stock Godot 4.7.2 Android templates ship every renderer and 3D module,
even though NeonNotes is a 2D app using `gl_compatibility` and has no 3D,
audio, or Godot-multiplayer content. The arm64 native library alone is 71.1 MB;
the release APK is 78.3 MB. The project carries two feature profiles:

- `2D-V1` — disables 3D nodes/rendering, 3D physics/navigation, XR, Godot
  Physics 3D, and Jolt.
- `2D-V2` — V1 plus Vulkan/glslang/Swappy, 2D physics/navigation, raycast/
  Embree, VisualShader, audio codecs, the multiplayer stack, camera/noise, and
  unused image formats.

Android presets use Gradle because the SharePlugin and MarkdownOpen plugins
ship AARs. With Gradle enabled, `custom_template/debug|release` is ignored; the
export packages the installed build template's
`android/build/libs/<type>/godot-lib.template_<type>.aar`.

## Decision

Build the Android AARs from a `4.7.2-stable` engine checkout with `2D-V2`, and
replace the official AARs inside the project's installed build template.

- `template_release` uses `production=yes` (static libc++, no debug symbols)
  and `template_debug` is a regular dev build.
- The AAR keeps the version-matched Java code, so only the native library
  changes.
- Keep the modules the app actually uses: `gdscript`, `mbedtls` (Crypto/
  hashing), `zip`, `regex`, `jpg`/`webp`, and `text_server_adv` with
  freetype/harfbuzz/icu/msdfgen.
- `2D-V2` is GLES3-only (`vulkan=no`); the app must keep `gl_compatibility`
  and its `.mobile` override. `2D-V1` remains the Vulkan-capable fallback.
- `tools/build_android_custom.sh [--export]` reproduces the build: scons for
  both targets, Gradle AAR assembly, backup/install into
  `android/build/libs/`, optional APK export. `BUILD_PROFILE` selects V1/V2.
- The engine NDK version is read from the checkout
  (`29.0.14206865` for 4.7.2) so the script and the source cannot drift.

## Consequences

- Release APK 78.3 MB → 48.6 MB; debug 84.3 MB → 52.5 MB; native library
  71.1 MB → 41.4 MB. V2 is 26.0% smaller than V1 and 37.9% smaller than stock.
- The app stays on the same Godot version and `gl_compatibility`; the only
  app-side adaptation is the graph's ArrayMesh unit quad (below). Vault and
  renderer behavior are unchanged.
- The Android template has **no Vulkan driver**. Switching the project to
  `forward_plus`/`mobile` works in the editor and fails on device; use V1 if
  Vulkan is ever required (GOT-023).
- Dropping a "kept" module (mbedtls, zip, regex, jpg/webp, text server) only
  breaks the exported app because the editor still provides it (INV-108).
- The build now depends on an engine checkout at the editor's exact version,
  plus JDK 17, SDK `cmdline-tools`, and `pkg-config`. After a Godot upgrade the
  AARs must be rebuilt, or the editor falls back to the official template.
- `android/build/` and the AARs are gitignored; a fresh clone installs the
  build template from the editor, then runs the script.
- The AAR is arm64-only, matching the presets. Adding an ABI means building it
  before assembling the AAR.
- `disable_3d` removes 3D resource classes as well as nodes. The graph's 2D
  `MultiMeshInstance2D` layers therefore build their quad as an `ArrayMesh`
  (`GraphView._node_quad`) instead of `QuadMesh` (GOT-021).
- Editing a profile requires rebuilding **both** targets; an incremental
  scons run does not rebuild the other variant.
- Verified on a Samsung SM-A165M: both V2 APKs boot to `OnGodotMainLoopStarted`,
  render the note UI, and open/close the graph cleanly.
- Related: ADR-0007 (scene-first), ADR-0012 (Android Open-with).
