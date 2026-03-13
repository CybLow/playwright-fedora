#!/usr/bin/env bash
# One-liner installer for playwright-fedora
# Usage: curl -fsSL https://raw.githubusercontent.com/CybLow/playwright-fedora/main/install.sh | bash
set -euo pipefail

REPO="https://github.com/CybLow/playwright-fedora.git"
TMPDIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Installing playwright-fedora..."

if ! git clone --depth=1 "$REPO" "$TMPDIR/playwright-fedora" 2>&1 | tail -1; then
    echo "ERROR: Failed to clone $REPO" >&2
    exit 1
fi

cd "$TMPDIR/playwright-fedora"

if ! bash setup.sh --install; then
    echo "ERROR: setup.sh --install failed" >&2
    exit 1
fi

echo ""
echo "Wrappers installed. Now run the full setup:"
echo ""
echo "  1. Restart your shell (or run: source ~/.bashrc)"
echo "  2. Run: pw setup"
echo ""
echo "This will install system dependencies, download compat libraries,"
echo "install Playwright browsers, and verify everything works."
