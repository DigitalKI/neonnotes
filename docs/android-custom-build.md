# Custom Android engine build

NeonNotes ships a 2D-only Godot Android build. `2D-V2` is the default;
`2D-V1` is the conservative fallback. The stock 4.7.2 templates include every
renderer and module, including 3D and Vulkan, even though the app uses
`gl_compatibility` and has no 3D or audio content.

| Artifact | Official 4.7.2 | `2D-V1` | `2D-V2` | V2 vs stock | V2 vs V1 |
|---|---:|---:|---:|---:|---:|
| `libgodot_android.so` (arm64) | 71.1 MB | 58.5 MB | 41.4 MB | −41.7% | −29.2% |
| `NeonNotes-release.apk` | 78.3 MB | 65.7 MB | 48.6 MB | −37.9% | −26.0% |
| `NeonNotes-debug.apk` | 84.3 MB | 70.0 MB | 52.5 MB | −37.8% | −25.1% |

## What `2D-V2` removes

- Vulkan rendering driver, `glslang`, and Swappy (Swappy is only wired for
  Vulkan here). The build is **GLES3-only**; `project.godot` must stay on
  `gl_compatibility` (GOT-023).
- 3D nodes/rendering, 3D physics/navigation, XR — inherited from `2D-V1`.
- 2D physics and navigation (`disable_physics_2d`, `disable_navigation_2d`).
- 3D occlusion culling/raycast + Embree, and VisualShader.
- Audio codecs and interactive music (the app has no audio).
- Multiplayer, ENet, WebSocket, WebRTC, UPnP, and JSON-RPC (LAN sync is custom).
- Camera and noise modules.
- Unused image/texture formats: SVG, BMP, TGA, DDS, KTX, HDR, EXR, Basis,
  astcenc, etcpak, bcdec (the vault uses lossless PNG/JPEG/WebP).
- The ObjectDB profiler in debug templates.

## What must stay

These are not optional; the editor still has them, so removing one only breaks
the exported app (INV-108):

- `gdscript` — the whole app.
- `mbedtls` — `Crypto` and `HashingContext` (vault IDs, sync challenge,
  SHA-256/MD5).
- `zip`/minizip — `ZIPReader`/`ZIPPacker` backup and import.
- `regex` — wiki-link parsing and move-link rewriting.
- `jpg`/`webp` — media import; PNG is core.
- `text_server_adv` + freetype/harfbuzz/icu/msdfgen — UI fonts and fallbacks.
- GLES3 renderer, zlib, zstd, and the Android/OpenSL platform layer.

## How the Gradle export picks up the custom engine

The Android presets use Gradle (`gradle_build/use_gradle_build=true`) because
`addons/SharePlugin` and `addons/MarkdownOpen` need their AARs compiled in.
With Gradle enabled, `custom_template/debug|release` is **ignored** — the
engine hides those options when Gradle is active. Instead, the export packages
the build template installed in the project:

```text
android/build/libs/<debug|release>/godot-lib.template_<debug|release>.aar
```

That AAR contains the version-matched Java code and the native
`jni/arm64-v8a/libgodot_android.so`. The script rebuilds the AAR from the
engine source with the profile and replaces the official one, keeping the Java
side identical to the editor version.

## Prerequisites

- **Engine source at the matching version.** The checkout used here is
  `~/Projects/Godot/godot-4.7.2`, tag `4.7.2-stable`, matching
  `android/.build_version` and the editor. A different version needs its own
  checkout and template install.
- **JDK 17** (Editor Settings ▸ Export ▸ Android ▸ Java SDK Path).
- **Android SDK with `cmdline-tools`.** The engine pins NDK `29.0.14206865`
  (`platform/android/detect.py`); scons installs it through `sdkmanager` when
  missing.
- **`pkg-config` on `PATH`.** Godot's scons build aborts without it even for
  Android, which links no system libraries.
- **The project's Android build template installed** (Project ▸ Install
  Android Build Template… in the editor). `android/build/` is machine-local
  and gitignored; a fresh clone must install it before running the script.

## Build

```bash
./tools/build_android_custom.sh            # compile + install the AARs
./tools/build_android_custom.sh --export   # ...then export both APKs
```

`2D-V2` is the default. For the conservative build without the module/Vulkan
cuts, use:

```bash
BUILD_PROFILE="$PWD/2D-V1" ./tools/build_android_custom.sh --export
```

The script:

1. Reads the required NDK version from the engine source and exports
   `ANDROID_HOME`, `JAVA_HOME`, and `ANDROID_NDK_ROOT`.
2. Installs the Swappy frame-pacing static libraries if they are missing
   (harmless for V2, which has no Vulkan driver to use them).
3. Runs two scons builds with
   `platform=android arch=arm64 build_profile=<profile> swappy=yes`:
   `template_release` (`production=yes`) and `template_debug`.
4. Runs `./gradlew :lib:assembleTemplateRelease :lib:assembleTemplateDebug` in
   `platform/android/java`.
5. Backs up each installed AAR once as `*.aar.official` and copies the rebuilt
   AAR into `android/build/libs/{release,debug}/`.
6. Caps Gradle at 1.5 GB in `android/build/gradle.properties`; the Gradle
   export reads that file.

Override defaults with environment variables: `GODOT_SRC`, `GODOT_BIN`,
`ANDROID_HOME`, `JAVA_HOME`, `BUILD_PROFILE`, `ARCH` (default `arm64`),
`JOBS` (default `2`), `GRADLE_HEAP`.

At `JOBS=3` on 8 cores / 14 GB, each native build takes about 7 minutes; the
Gradle AAR steps are under a minute.

After an upgrade, rerun the script with the new engine checkout; the Java
source and native library must come from the same Godot version.

## Rollback

- Copy `android/build/libs/release/godot-lib.template_release.aar.official` and
  the debug equivalent back over the custom AAR for the **stock** engine.
- Local `*.aar.v1` backups hold the previous conservative `2D-V1` AARs.
- Or delete `android/build/` and install the build template again from the
  editor; the official AARs come back with it.
- `build/NeonNotes-*.apk.official` are the pre-custom exports;
  `build/NeonNotes-*.apk.v1` are the `2D-V1` exports.

## Notes and limits

- The AAR is **arm64 only**, matching both presets (`arm64-v8a=true`, all other
  architectures false). To support another ABI, run the scons builds for that
  `ARCH`, then assemble the AARs once and install them; a single AAR can hold
  several `jni/<abi>/` directories.
- `2D-V2` is GL-only. If the app ever needs Forward+/Mobile, use `2D-V1`
  (Vulkan + Swappy) or rebuild V2 with `vulkan=yes` (GOT-023).
- Disabling classes is enforced at compile time by
  `core/disabled_classes.gen.h`; instantiating `Node3D` in engine code fails
  the build. The app uses no 3D nodes (`3d/physics_engine="Dummy"`).
- `disable_3d` also drops 3D *resource* classes. The graph's
  `MultiMeshInstance2D` marker layers need a `Mesh`, so `GraphView` builds an
  `ArrayMesh` unit quad (`_node_quad`) instead of `QuadMesh`; keep 2D
  MultiMeshes on an `ArrayMesh` under this profile (GOT-021).
- Verified on a Samsung SM-A165M: both V2 APKs reach `OnGodotMainLoopStarted`,
  render the note UI, and open/close the graph without script or shader errors.
- Further size work is limited by core features: GDScript, TextServer/ICU,
  GLES3, and the image/crypto/zip modules the app uses. The RD renderer is
  already dead-stripped with `vulkan=no`; Graphite/Brotli are under 0.5 MB
  static. `lto=thin` is the remaining non-feature lever, at link time and
  memory cost.
- The APKs are signed with the dev keystore. After an engine/profile change,
  install one and watch `adb logcat | grep 'godot   :'` for
  `OnGodotMainLoopStarted` before shipping.
