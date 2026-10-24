# ADR-0015 — Desktop releases are portable, versioned archives

_Status: accepted · 2026-10-21_

## Context

Linux and Windows builds were exported ad hoc: a bare ELF or EXE next to a
loose `.pck`, an unversioned filename, no Linux launcher entry or icons, and no
Windows preset at all. Users could not tell builds apart, and installing meant
copying files by hand.

## Decision

- Export with the PCK **embedded** in the executable: one file per platform.
- Publish **versioned archives** (`NeonNotes-<version>-<os>-<arch>`) plus
  `SHA256SUMS`; no installer is required.
- Linux archives carry an XDG `.desktop` entry, AppStream metainfo, hicolor
  icons, and an `install.sh` for `~/.local` (or `PREFIX`). An AppImage can be
  built when `appimagetool` is available.
- Windows executables embed the multi-size `.ico` and VERSIONINFO metadata;
  the console wrapper stays off.
- Icons are generated from one committed master into committed PNG/ICO assets,
  so an export does not depend on an imaging tool.

## Consequences

- `tools/package_desktop.sh` is the release path; the version lives in
  `project.godot` and the presets in `export_presets.cfg`.
- Code signing (Authenticode) and Linux signing are still external steps; the
  archives are unsigned for now.
- Open-with for `.md` is not advertised in the desktop entry until the app
  handles a file argument at boot (roadmap).
