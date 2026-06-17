# Changelog

All notable changes to **Leenx Installer** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-06-17

### Added

- **GUI application** — macOS-style window with custom traffic-light title bar, drag-and-drop source card, and real install progress.
- **Archive extraction** — Pure-Dart decompression of `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tgz`, `.zip`, and `.AppImage` via the `archive` package.
- **XDG-compliant installation** — Extracts to `~/.local/share/installer-apps/<name>/` and writes a `.desktop` launcher to `~/.local/share/applications/installer-<name>.desktop`. No sudo required.
- **Executable detection** — Scans extracted trees for executables, intelligently skipping `lib/` and `runtime/` helpers like `jspawnhelper`.
- **Live install progress** — Real-time phase updates ("Reading archive", "Extracting 24/87", "Creating launcher") with a circular progress indicator.
- **Installed apps library** — Slide-in sidebar (320px) listing all installed apps with per-row actions: Open folder, Edit launcher, Uninstall.
- **Launcher editor** — Full monospace `.desktop` file editor with `[Desktop Entry]` header validation, Save / Cancel / Reset, and `update-desktop-database` refresh.
- **Drop validation** — Unsupported file types (`.apk`, `.iso`, etc.) trigger a red glow, damped-sine shake animation, and clear error message directly on the source card.
- **Running-process guard** — Refuses to uninstall an app whose binary is currently running (scans `/proc/<pid>/exe`).
- **Animated uninstall dialog** — Custom `showGeneralDialog` with slide-up, scale-in (`easeOutBack` bounce), and fade entrance.
- **Headless CLI** — Standalone `bin/leenx.dart` (compiled native binary via `dart compile exe`). Subcommands: `install`, `list`, `uninstall`.
- **Full-bleed background** — Aurora photo with dark wash-out gradient overlay and radial vignette. Scales to fill the window on maximize.
- **Window resize** — Minimum size 720×540, content constrained to 820px max-width for comfortable readability.
- **Drag-to-move title bar** — `DragToMoveArea` widget from `window_manager` for the center title area.

### Fixed

- **Launcher correctness** — `Exec=` now points to the absolute path of the found executable (no wrapper, no `Path=`). JVM launchers like ABDownloadManager resolve correctly.
- **Invalid file acceptance** — Extension whitelist enforced; `.apk`, `.exe`, `.iso`, and other unsupported types are rejected with a friendly message including the actual extension.
- **Uninstall while running** — Scans `/proc/<pid>/exe` and refuses to delete if a process is using the app directory.

### Dependencies

| Package | Version |
|---------|---------|
| `flutter` | ≥3.10 (SDK) |
| `window_manager` | ^0.5.1 |
| `desktop_drop` | ^0.7.1 |
| `archive` | ^4.0.9 |
| `cross_file` | ^0.3.5 |

---

## [0.1.0] — 2026-06-17

### Added

- Project scaffold with Flutter Linux platform.
- Single-file `lib/main.dart` architecture.
- macOS-style dark theme with gradient background.
- Initial drag-and-drop skeleton (in-app mock cards, no real extraction).

---

[1.0.0]: https://github.com/AxDSan/leenx-installer/releases/tag/v1.0.0
[0.1.0]: https://github.com/AxDSan/leenx-installer/releases/tag/v0.1.0
