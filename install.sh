#!/usr/bin/env bash
#
# Leenx Installer — one-liner installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AxDSan/leenx-installer/main/install.sh | bash
#
# What it does:
#   1. Tries to download the latest prebuilt release tarball from GitHub Releases.
#   2. Falls back to building from source if Flutter is installed and no release exists.
#   3. Installs the GUI bundle to ~/.local/share/leenx/.
#   4. Drops a dispatcher at ~/.local/bin/leenx:
#        - bare `leenx`          → launches the GUI (leenx_installer)
#        - `leenx install <f>`   → runs the bundled CLI installer
#        - `leenx list`          → lists installed apps
#        - `leenx uninstall <n>` → uninstalls an app
#
set -euo pipefail

REPO="AxDSan/leenx-installer"
INSTALL_DIR="${LEENX_INSTALL_DIR:-$HOME/.local/share/leenx}"
BIN_DIR="${LEENX_BIN_DIR:-$HOME/.local/bin}"
WRAPPER="$BIN_DIR/leenx"
CLI_NAME="leenx"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [[ "${OSTYPE:-}" != linux* ]]; then
    echo "Error: Leenx Installer currently ships a Linux x86_64 bundle only." >&2
    exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Error: prebuilt bundle is x86_64 only. Build from source on other arches." >&2
    echo "       See: https://github.com/$REPO#building-from-source" >&2
    exit 1
fi

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found in PATH." >&2
        exit 1
    fi
done

echo ""
echo "  Leenx Installer"
echo "  ==============="
echo ""

# ---------------------------------------------------------------------------
# Resolve latest tag
# ---------------------------------------------------------------------------

latest_tag() {
    # Use the redirect target of /releases/latest — no auth, no rate limit pain.
    curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's#.*/tag/\(v[^"]*\).*#\1#p' | head -n1
}

download_release() {
    local tag="$1" tmpdir="$2"
    local url="https://github.com/$REPO/releases/download/$tag/leenx-${tag}-linux-x64.tar.gz"
    echo "Downloading $url"
    if ! curl -fL --retry 3 --retry-delay 1 -o "$tmpdir/release.tar.gz" "$url"; then
        return 1
    fi
    tar -xzf "$tmpdir/release.tar.gz" -C "$tmpdir"
    # Tarball layout: leenx-<tag>-linux-x64/{bundle..., leenx (CLI)}
    local extracted
    extracted=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'leenx-*-linux-x64' | head -n1)
    if [[ -z "$extracted" ]]; then
        echo "Error: unexpected tarball layout — no leenx-*-linux-x64 directory found." >&2
        return 1
    fi
    RELEASE_BUNDLE_DIR="$extracted"
}

build_from_source() {
    local tmpdir="$1"
    if ! command -v flutter >/dev/null 2>&1; then
        echo "Error: no release available and Flutter is not installed." >&2
        echo "       Install Flutter: https://docs.flutter.dev/get-started/install/linux" >&2
        return 1
    fi

    echo "No prebuilt release found — building from source (Flutter: $(flutter --version | head -n1))"
    echo ""

    echo "Cloning repository..."
    git clone --depth 1 "https://github.com/$REPO.git" "$tmpdir/leenx-installer"

    pushd "$tmpdir/leenx-installer" >/dev/null

    echo "Resolving dependencies..."
    flutter pub get

    echo "Building Linux release bundle (this can take a few minutes)..."
    flutter config --enable-linux-desktop >/dev/null
    flutter build linux --release

    echo "Compiling CLI..."
    dart compile exe bin/leenx.dart -o "$tmpdir/leenx_cli"

    popd >/dev/null

    # Stage into a directory that matches the release layout
    RELEASE_BUNDLE_DIR="$tmpdir/leenx-src-stage"
    mkdir -p "$RELEASE_BUNDLE_DIR"
    cp -r "$tmpdir/leenx-installer/build/linux/x64/release/bundle/." "$RELEASE_BUNDLE_DIR/"
    cp "$tmpdir/leenx_cli" "$RELEASE_BUNDLE_DIR/leenx"
    chmod +x "$RELEASE_BUNDLE_DIR/leenx"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TAG="$(latest_tag || true)"
RELEASE_BUNDLE_DIR=""

if [[ -n "$TAG" ]]; then
    if ! download_release "$TAG" "$TMP_DIR"; then
        echo "Release download failed — falling back to source build."
        echo ""
        build_from_source "$TMP_DIR" || exit 1
    fi
else
    echo "No GitHub release found yet."
    build_from_source "$TMP_DIR" || exit 1
fi

echo ""
echo "Installing to $INSTALL_DIR ..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$RELEASE_BUNDLE_DIR/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/leenx_installer" "$INSTALL_DIR/leenx" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Wrapper (dispatcher)
# ---------------------------------------------------------------------------

echo "Creating dispatcher at $WRAPPER ..."
mkdir -p "$BIN_DIR"

cat > "$WRAPPER" <<EOF
#!/bin/sh
# Leenx dispatcher: bare invocation launches the GUI, anything else goes to the CLI.
set -e
GUI="\$HOME/.local/share/leenx/leenx_installer"
CLI="\$HOME/.local/share/leenx/leenx"

if [ "\$#" -eq 0 ]; then
    if [ -z "\${DISPLAY:-}\${WAYLAND_DISPLAY:-}" ]; then
        echo "leenx: no graphical session detected (DISPLAY/WAYLAND_DISPLAY unset)." >&2
        echo "       Use the CLI instead: leenx install <archive> | leenx list | leenx --help" >&2
        exit 1
    fi
    exec "\$GUI"
fi

# GUI passthrough for explicit flags; everything else → CLI.
case "\$1" in
    --gui|-g|launch|open)
        exec "\$GUI"
        ;;
    --help|-h|help)
        cat <<USAGE
leenx — Leenx Installer CLI

Usage:
  leenx                     Launch the GUI
  leenx --gui               Launch the GUI explicitly
  leenx install <archive>   Install an archive (.tar.gz, .zip, .AppImage, ...)
  leenx list                List installed apps
  leenx uninstall <name|#>  Uninstall an app by name or list number
  leenx --help              Show this help

The GUI is a Flutter app for drag-and-drop installation of dropped archives.
USAGE
        exit 0
        ;;
esac

exec "\$CLI" "\$@"
EOF
chmod +x "$WRAPPER"

# ---------------------------------------------------------------------------
# PATH check
# ---------------------------------------------------------------------------

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "Note: $BIN_DIR is not on your PATH."
    echo "Add this to your ~/.bashrc (or ~/.zshrc) and reload:"
    echo ""
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Installation complete."
echo ""
echo "Try it:"
echo "    leenx              # launch the GUI"
echo "    leenx --help       # CLI usage"
echo ""
echo "Direct paths:"
echo "    GUI: $INSTALL_DIR/leenx_installer"
echo "    CLI: $INSTALL_DIR/leenx"
echo "    Wrapper: $WRAPPER"
echo ""