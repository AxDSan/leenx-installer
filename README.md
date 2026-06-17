<p align="center">
  <img src="https://raw.githubusercontent.com/AxDSan/leenx-installer/main/assets/hero.jpg" width="820" alt="Leenx Installer hero">
</p>

<!--
HERO IMAGE (T2I Prompt for DALL·E / Midjourney / Stable Diffusion):

A dark, modern macOS-style desktop installer window floating in deep space.
The window shows a drag-and-drop interface: on the left, a file card with a
tar.gz icon; on the right, a home folder icon. A glowing blue arrow connects
them. A circular progress indicator pulses between them. The background is a
deep aurora with dark mountains silhouetted against a night sky. Subtle macOS
traffic light controls (red, yellow, green) sit in the title bar. The window
has a frosted glass feel. Text reads "Install Application" and "Drop a
flatpak archive". Design style: clean, high-contrast, dark theme, cyberpunk
utilitarian. --ar 16:9 --v 6
-->

<h1 align="center">Leenx Installer</h1>

<p align="center">
  <strong>A macOS-style desktop installer that <em>actually</em> installs things.</strong><br>
  Drag a <code>.tar.gz</code>, <code>.zip</code>, or <code>.AppImage</code> onto the card → unpack it to <code>~/.local/share</code> → get a working launcher.
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#screenshots">Screenshots</a> •
  <a href="#getting-started">Getting Started</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#usage">Usage</a>
</p>

---

## Features

- **Drag-and-drop install** — Drop a `.tar.gz`, `.zip`, `.tar.bz2`, `.tar.xz`, or `.AppImage` onto the source card.
- **Real extraction** — Uses the `archive` Dart package to decompress and extract in-process. Supports gzip, bzip2, xz, and zip archives.
- **XDG-compliant** — Installs to `~/.local/share/installer-apps/<name>/` and creates a `.desktop` launcher at `~/.local/share/applications/installer-<name>.desktop`. No sudo. Full XDG Base Directory spec.
- **Executable detection** — Scans the extracted tree for executable files, skips `lib/` and `runtime/` helpers like `jspawnhelper`. Picks the best match.
- **Live progress** — Real-time extraction progress with phases ("Reading archive", "Extracting 24/87", "Creating launcher").
- **Installed apps library** — Side‑panel tracks every app you've installed. Open folder, edit the `.desktop` launcher, or uninstall.
- **Built-in launcher editor** — Full monospace text editor for `.desktop` files. Validates `[Desktop Entry]` header. Saves with `update-desktop-database` refresh.
- **Running‑process guard** — Refuses to uninstall an app that's currently running (scans `/proc/<pid>/exe`).
- **Animated uninstall dialog** — Slide + scale + fade entrance with a red delete confirmation.
- **Drop validation** — Unsupported file types (`.apk`, `.iso`, etc.) get a red glow + shake animation on the source card with a friendly error message.
- **Mac‑style title bar** — Custom macOS traffic light controls (close, minimize, maximize) with a draggable title area. Works on Linux via `window_manager`.
- **Full‑bleed background** — Dark aurora photo with a wash‑out gradient overlay and vignette. Fills the window on maximize — no fixed card in an empty void.
- **Resizable** — Minimum window size 720×540, content constrained to 820px max-width for comfortable readability at any scale.

---

## Screenshots

| Install view | Installed apps panel | Launcher editor |
|-------------|----------------------|----------------|
| ![install](https://raw.githubusercontent.com/AxDSan/leenx-installer/main/assets/screenshot-install.jpg) | ![apps](https://raw.githubusercontent.com/AxDSan/leenx-installer/main/assets/screenshot-apps.jpg) | (coming soon) |

---

## Architecture

The entire application is a **single file** — `lib/main.dart` — keeping it self-contained and easy to audit. Rough layout:

| Section | Lines | Purpose |
|---------|-------|---------|
| `main()` + `InstallerApp` | 1—44 | Window setup via `window_manager`, Material app with dark theme |
| `_InstallerWindowState` | 90—550 | Main state machine: idle → installing → done → error. Apps panel toggle, editor modal, uninstall flows |
| Title bar / traffic lights | 560—700 | `_TitleBar` with `DragToMoveArea`, `_AppsToggleButton` with count badge |
| Source + destination cards | 790—1170 | `_SourceCard` (StatefulWidget, shake animation, drop target), `_DestinationCard` |
| Arrow / progress / labels | 1170—1260 | `_ArrowOrProgress`, `_PhaseLabel`, `_ErrorLabel`, `_DoneLabel` |
| Info cards + footer | 1260—1430 | Three info cards explaining the install model, footer with Install / Open folder / Uninstall buttons |
| `InstallerService` | 1640—1950 | Real extraction pipeline: `install()` async generator, `uninstall()`, `_writeDesktopFile()`, `_findExecutable()`, `_runningProcessesUnder()` |
| `AppsRegistry` | 1960—2030 | Scans `~/.local/share/installer-apps/` and pairs subdirs with `.desktop` files |
| `_AppsPanel` | 2030—2230 | Slide‑in sidebar with scrim, list, per‑row popup menu |
| `_LauncherEditor` | 2230—2600 | `DraggableScrollableSheet` with monospace `TextField`, Save / Cancel / Reset buttons, header validation |
| `showAnimatedUninstallDialog` | 2780—2860 | `showGeneralDialog` with `easeOutBack` slide‑scale transition |

### Key dependencies

| Package | Use |
|---------|-----|
| `window_manager` | Hidden native title bar, custom macOS traffic lights, drag‑to‑move |
| `desktop_drop` | OS‑level drag‑and‑drop of files onto the source card |
| `archive` | Pure‑Dart decompression of gzip, bzip2, xz, zip, tar |
| `path` | Cross‑platform path manipulation |

---

## Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) ≥ 3.10 (Linux or macOS)

### Clone & run

```bash
git clone https://github.com/AxDSan/leenx-installer.git
cd Leenx Installer
flutter pub get
flutter run -d linux
```

### Build a release binary

```bash
flutter build linux --release
./build/linux/x64/release/bundle/flutter_installer_ui
```

### Run tests

```bash
flutter test
```

---

## Usage

1. **Drag** a `.tar.gz`, `.zip`, or `.AppImage` from your file manager onto the source card. Unsupported types get a red shake + error.
2. **Click Install**. Progress phases appear in real time: decompressing, extracting (with counters), writing the `.desktop` launcher.
3. **Success**. The app is at `~/.local/share/installer-apps/<name>/` and a launcher appears in your KDE/GNOME menu (after a few seconds).
4. **Click Apps** in the title bar to see the installed apps panel. Per‑app actions:
   - **Open folder** — opens the install dir in Dolphin/Nautilus
   - **Edit launcher** — full `.desktop` text editor
   - **Uninstall** — animated confirmation dialog, then cleanup
5. **Re‑install** by clicking Reset and dropping the archive again.

### Uninstall temporarily disabled?

The app refuses to uninstall an app that's currently running. Close it first, or kill the process from a terminal.

---

## License

MIT — Do whatever you want.
