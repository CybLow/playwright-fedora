#!/usr/bin/env bash
# playwright-fedora-setup -- Install Playwright + all Fedora system dependencies
#
# Playwright's `install-deps` only supports Debian/Ubuntu.
# This script installs the equivalent Fedora packages, downloads compat
# libraries from Ubuntu 24.04, and patches WebKit wrappers so all 3 browser
# engines work correctly on Fedora.
#
# Usage:
#   ./setup.sh              # Full setup (deps + compat libs + browsers + verify)
#   ./setup.sh --deps-only  # Only install system deps + download compat libs
#   ./setup.sh --browsers   # Only install/update browsers + patch wrappers
#   ./setup.sh --patch      # Only patch WebKit wrappers (after manual browser install)
#   ./setup.sh --check      # Verify everything works
#   ./setup.sh --install    # Install pw wrapper + setup script to ~/.local
#   ./setup.sh --ci         # Non-interactive mode (no color, no TTY checks)
#   ./setup.sh --help

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────
COMPAT_DIR="${PLAYWRIGHT_COMPAT_DIR:-$HOME/.local/lib/playwright-compat}"
BROWSER_DIR="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
CI_MODE=false
MODE="full"

# ── Colors ─────────────────────────────────────────────────────
setup_colors() {
    if [ "$CI_MODE" = true ] || [ ! -t 1 ]; then
        RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
    else
        RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
        BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
    fi
}

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Architecture detection ────────────────────────────────────
# Returns "arch:libdir" for Ubuntu .deb packages
deb_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64:usr/lib/aarch64-linux-gnu" ;;
        *)       echo "amd64:usr/lib/x86_64-linux-gnu" ;;
    esac
}

# ── Parse arguments ────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --deps-only) MODE="deps" ;;
        --browsers)  MODE="browsers" ;;
        --patch)     MODE="patch" ;;
        --check)     MODE="check" ;;
        --install)   MODE="install" ;;
        --ci)        CI_MODE=true ;;
        --help|-h)
            cat <<'EOF'
Usage: setup.sh [OPTIONS]

Options:
  (no args)     Full setup: system deps + compat libs + browsers + verify
  --deps-only   Only install system deps + download compat libs
  --browsers    Only install/update Playwright browsers + patch wrappers
  --patch       Only patch WebKit wrappers (after npx playwright install)
  --check       Verify installation (launch each browser engine)
  --install     Install pw wrapper + setup script to ~/.local/bin
  --ci          Non-interactive mode (no color, suitable for Docker/CI)
  --help        Show this message

Environment:
  PLAYWRIGHT_COMPAT_DIR    Override compat lib location (default: ~/.local/lib/playwright-compat)
  PLAYWRIGHT_BROWSERS_PATH Override browser cache location (default: ~/.cache/ms-playwright)
EOF
            exit 0
            ;;
        *) die "Unknown argument: $arg (try --help)" ;;
    esac
done

setup_colors

# ── Verify Fedora ──────────────────────────────────────────────
verify_fedora() {
    if [ ! -f /etc/os-release ]; then
        die "Cannot detect OS (no /etc/os-release)"
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    if [ "$ID" != "fedora" ]; then
        die "This script is for Fedora (detected: $ID)"
    fi
    info "Detected Fedora $VERSION_ID"
    if [ "${VERSION_ID:-0}" -lt 39 ] 2>/dev/null; then
        warn "Fedora $VERSION_ID is older than the tested range (39-43). Things may not work."
    fi
}

# ── Install system dependencies ────────────────────────────────
install_deps() {
    info "Installing Playwright system dependencies..."

    # --- Tools (needed for downloading/extracting compat libraries) ---
    local tool_deps=(
        curl binutils zstd tar findutils
    )

    # --- Chromium / Chrome for Testing ---
    local chromium_deps=(
        nss nspr atk at-spi2-atk cups-libs libdrm
        libXcomposite libXdamage libXrandr mesa-libgbm
        pango cairo alsa-lib libxkbcommon
        libXfixes libXext libX11 libxcb
        dbus-libs expat libxshmfence
    )

    # --- Firefox ---
    local firefox_deps=(
        gtk3 dbus-glib
    )

    # --- WebKit ---
    local webkit_deps=(
        gstreamer1 gstreamer1-plugins-base
        gstreamer1-plugins-good gstreamer1-plugins-bad-free
        libsoup3 libgcrypt enchant2 libsecret
        hyphen libmanette openjpeg2 woff2
        harfbuzz-icu libwebp lcms2 libjxl
        libatomic mesa-libEGL mesa-libGLES mesa-libgbm
        libwayland-server gstreamer1-libav libavif flite
    )

    # --- General / shared ---
    local general_deps=(
        xorg-x11-fonts-Type1 xorg-x11-fonts-misc
        fontconfig freetype libpng libjpeg-turbo
        libxml2 libxslt zlib
    )

    local all_deps=(
        "${tool_deps[@]}"
        "${chromium_deps[@]}"
        "${firefox_deps[@]}"
        "${webkit_deps[@]}"
        "${general_deps[@]}"
    )

    if [ "$(id -u)" -eq 0 ]; then
        dnf install -y --skip-unavailable "${all_deps[@]}" 2>&1 | tail -3
    else
        sudo dnf install -y --skip-unavailable "${all_deps[@]}" 2>&1 | tail -5
    fi
    ok "System dependencies installed"

    # Install compat libs for WebKit
    install_webkit_compat
}

# ── Install WebKit compat libraries ───────────────────────────
install_webkit_compat() {
    info "Installing WebKit compatibility libraries..."

    # --- libjpeg-turbo with JPEG8 ABI ---
    # Fedora exports LIBJPEG_6.2 version symbols; Playwright's Ubuntu-built
    # WebKit expects LIBJPEG_8.0. We download Ubuntu's libjpeg-turbo8 package
    # which provides libjpeg.so.8 with the correct symbols.
    if [ -f "$COMPAT_DIR/lib64/libjpeg.so.8" ]; then
        local existing_sym
        existing_sym=$(objdump -p "$COMPAT_DIR/lib64/libjpeg.so.8" 2>/dev/null | grep -o 'LIBJPEG_8.0' || true)
        if [ "$existing_sym" = "LIBJPEG_8.0" ]; then
            ok "Compat libjpeg (LIBJPEG_8.0) already installed"
        else
            download_compat_libjpeg
        fi
    else
        download_compat_libjpeg
    fi

    # --- libjxl soversion symlink ---
    mkdir -p "$COMPAT_DIR"
    local system_libjxl
    system_libjxl=$(find /usr/lib64 -name 'libjxl.so.0.*' -not -type l 2>/dev/null | head -1)
    if [ -n "$system_libjxl" ] && [ ! -e "$COMPAT_DIR/libjxl.so.0.8" ]; then
        ln -sf "$system_libjxl" "$COMPAT_DIR/libjxl.so.0.8"
        ok "Created compat symlink: libjxl.so.0.8 -> $(basename "$system_libjxl")"
    fi

    # --- ICU compat libraries ---
    # Playwright's WebKit is built on Ubuntu 24.04 (ICU 74). Fedora ships newer
    # ICU versions (75-77+) which are NOT ABI-compatible. We extract Ubuntu's
    # libicu74 package into the compat directory.
    install_icu_compat
}

install_icu_compat() {
    local icu_dir="$COMPAT_DIR/icu"
    if [ -f "$icu_dir/libicudata.so.74" ]; then
        ok "ICU 74 compat libs already installed"
        return
    fi

    # Check if system ICU is already 74 (no compat needed)
    if [ -f /usr/lib64/libicudata.so.74 ]; then
        ok "System ICU is version 74 (no compat needed)"
        return
    fi

    info "Installing ICU 74 compat libraries for WebKit..."

    local arch_info lib_arch lib_dir
    arch_info=$(deb_arch)
    lib_arch="${arch_info%%:*}"
    lib_dir="${arch_info#*:}"

    local tmp_dir="/tmp/playwright-icu-compat-$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir" "$icu_dir"

    # Download libicu74 from Ubuntu 24.04 (noble)
    # Try multiple package versions since Ubuntu updates revisions
    local downloaded=false
    for deb_ver in 74.2-1ubuntu3 74.2-1ubuntu4 74.2-1ubuntu3.1; do
        local deb_url="https://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_${deb_ver}_${lib_arch}.deb"
        if curl -fsSL -o "$tmp_dir/libicu74.deb" "$deb_url" 2>/dev/null; then
            downloaded=true
            break
        fi
    done
    if [ "$downloaded" = false ]; then
        warn "Could not download ICU 74 package. WebKit may not work."
        rm -rf "$tmp_dir"
        return
    fi

    # Extract .deb (it's an ar archive containing data.tar)
    pushd "$tmp_dir" >/dev/null
    if ! ar x libicu74.deb 2>/dev/null; then
        warn "Failed to extract ICU .deb package"
        popd >/dev/null; rm -rf "$tmp_dir"; return
    fi

    local data_tar
    data_tar=$(ls data.tar.* 2>/dev/null | head -1)
    if [ -z "$data_tar" ]; then
        warn "No data.tar found in ICU .deb"
        popd >/dev/null; rm -rf "$tmp_dir"; return
    fi

    local tar_flags=""
    case "$data_tar" in
        *.zst) tar_flags="--zstd" ;;
        *.xz)  tar_flags="-J" ;;
        *.gz)  tar_flags="-z" ;;
    esac
    tar $tar_flags -xf "$data_tar" "./$lib_dir/" 2>/dev/null || true
    popd >/dev/null

    # Copy ICU libs to compat directory
    local extracted="$tmp_dir/$lib_dir"
    if [ -d "$extracted" ]; then
        cp -a "$extracted"/libicu*.so.74* "$icu_dir/" 2>/dev/null || true
        local count
        count=$(find "$icu_dir" -name 'libicu*.so.74*' -type f 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            ok "Installed $count ICU 74 compat libraries -> $icu_dir/"
        else
            warn "ICU 74 extraction produced no libraries"
        fi
    else
        warn "Could not extract ICU 74 libraries from deb package"
    fi

    rm -rf "$tmp_dir"
}

download_compat_libjpeg() {
    info "Installing libjpeg with JPEG8 ABI (LIBJPEG_8.0 symbols)..."

    local arch_info lib_arch lib_dir
    arch_info=$(deb_arch)
    lib_arch="${arch_info%%:*}"
    lib_dir="${arch_info#*:}"

    local tmp_dir="/tmp/playwright-libjpeg-compat-$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir" "$COMPAT_DIR/lib64"

    # Download Ubuntu 24.04's libjpeg-turbo8 package (provides libjpeg.so.8
    # with LIBJPEG_8.0 symbols that Playwright's WebKit requires)
    local downloaded=false
    for deb_ver in 2.1.5-2ubuntu2 2.1.5-2ubuntu1 2.1.5-2build1; do
        local url="https://archive.ubuntu.com/ubuntu/pool/main/libj/libjpeg-turbo/libjpeg-turbo8_${deb_ver}_${lib_arch}.deb"
        if curl -fsSL -o "$tmp_dir/libjpeg8.deb" "$url" 2>/dev/null; then
            downloaded=true
            break
        fi
    done

    if [ "$downloaded" = false ]; then
        warn "Could not download libjpeg-turbo8 package. WebKit may not work."
        rm -rf "$tmp_dir"
        return
    fi

    # Extract .deb (it's an ar archive containing data.tar)
    pushd "$tmp_dir" >/dev/null
    if ! ar x libjpeg8.deb 2>/dev/null; then
        warn "Failed to extract libjpeg .deb package"
        popd >/dev/null; rm -rf "$tmp_dir"; return
    fi

    local data_tar
    data_tar=$(ls data.tar.* 2>/dev/null | head -1)
    if [ -z "$data_tar" ]; then
        warn "No data.tar found in libjpeg .deb"
        popd >/dev/null; rm -rf "$tmp_dir"; return
    fi

    local tar_flags=""
    case "$data_tar" in
        *.zst) tar_flags="--zstd" ;;
        *.xz)  tar_flags="-J" ;;
        *.gz)  tar_flags="-z" ;;
    esac
    tar $tar_flags -xf "$data_tar" "./$lib_dir/" 2>/dev/null || true
    popd >/dev/null

    # Copy libjpeg files to compat directory
    local extracted="$tmp_dir/$lib_dir"
    if [ -d "$extracted" ]; then
        cp -a "$extracted"/libjpeg.so.8* "$COMPAT_DIR/lib64/" 2>/dev/null || true
        # Create libjpeg.so.8 symlink if only the versioned file was copied
        if [ ! -e "$COMPAT_DIR/lib64/libjpeg.so.8" ]; then
            local versioned
            versioned=$(ls "$COMPAT_DIR/lib64"/libjpeg.so.8.* 2>/dev/null | head -1)
            if [ -n "$versioned" ]; then
                ln -sf "$(basename "$versioned")" "$COMPAT_DIR/lib64/libjpeg.so.8"
            fi
        fi
        ok "Installed compat libjpeg -> $COMPAT_DIR/lib64/"
    else
        warn "Could not extract libjpeg from .deb package"
    fi

    rm -rf "$tmp_dir"
}

# ── Patch WebKit MiniBrowser wrappers ──────────────────────────
patch_webkit_wrappers() {
    local compat_lib_dir="$COMPAT_DIR/lib64"
    local patched=0

    # Scan both default and custom browser paths
    local search_dirs=("$BROWSER_DIR")
    # Also check PLAYWRIGHT_BROWSERS_PATH if different
    if [ "$BROWSER_DIR" != "$HOME/.cache/ms-playwright" ] && [ -d "$HOME/.cache/ms-playwright" ]; then
        search_dirs+=("$HOME/.cache/ms-playwright")
    fi

    for base_dir in "${search_dirs[@]}"; do
        for webkit_dir in "$base_dir"/webkit-*/; do
            [ -d "$webkit_dir" ] || continue
            for wrapper in "$webkit_dir"minibrowser-{gtk,wpe}/MiniBrowser; do
                [ -f "$wrapper" ] || continue
                if grep -q 'playwright-compat' "$wrapper" 2>/dev/null; then
                    continue
                fi
                if grep -q 'export LD_LIBRARY_PATH=' "$wrapper"; then
                    sed -i "s|export LD_LIBRARY_PATH=\"|export LD_LIBRARY_PATH=\"\${HOME}/.local/lib/playwright-compat/lib64:\${HOME}/.local/lib/playwright-compat/icu:\${HOME}/.local/lib/playwright-compat:|" "$wrapper"
                    patched=$((patched + 1))
                fi
            done
        done
    done

    if [ "$patched" -gt 0 ]; then
        ok "Patched $patched WebKit MiniBrowser wrapper(s)"
    else
        ok "WebKit wrappers already patched (or not yet installed)"
    fi
}

# ── Install Playwright npm package ─────────────────────────────
install_playwright_npm() {
    if ! command -v node &>/dev/null; then
        die "Node.js not found. Install with: sudo dnf install nodejs"
    fi

    # Detect if playwright is already available
    if npx playwright --version &>/dev/null 2>&1; then
        local ver
        ver=$(npx playwright --version 2>/dev/null || echo "unknown")
        ok "Playwright already available (v${ver})"
    else
        info "Installing Playwright..."
        if command -v bun &>/dev/null; then
            bun install -g playwright @playwright/test
        elif command -v pnpm &>/dev/null; then
            pnpm add -g playwright @playwright/test
        else
            npm install -g playwright @playwright/test
        fi
        ok "Playwright installed"
    fi
}

# ── Install browsers ───────────────────────────────────────────
install_browsers() {
    info "Installing Playwright browsers (Chromium, Firefox, WebKit)..."
    npx playwright install chromium firefox webkit 2>&1
    ok "All browsers installed"

    # Auto-patch WebKit wrappers
    patch_webkit_wrappers

    if [ -d "$BROWSER_DIR" ]; then
        info "Browser cache: $BROWSER_DIR"
        du -sh "$BROWSER_DIR" 2>/dev/null | awk '{print "  Total size: " $1}'
    fi
}

# ── Check / verify ─────────────────────────────────────────────
check_installation() {
    # Run in subshell to avoid leaking LD_LIBRARY_PATH and env vars
    (
    info "Verifying Playwright installation..."
    echo ""

    export LD_LIBRARY_PATH="${COMPAT_DIR}/lib64:${COMPAT_DIR}/icu:${COMPAT_DIR}:${LD_LIBRARY_PATH:-/usr/lib64}"
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

    local all_good=true

    if npx playwright --version &>/dev/null; then
        ok "playwright CLI: $(npx playwright --version 2>/dev/null)"
    else
        err "playwright CLI not found"
        all_good=false
    fi

    for browser in chromium firefox webkit; do
        if [ "$browser" = "webkit" ] && ! ls -d "$BROWSER_DIR/webkit-"* &>/dev/null 2>&1; then
            warn "webkit: not installed"
            continue
        fi

        # Try require('playwright'), then fallback to require('playwright-core')
        local test_script="
            (async () => {
                let pw;
                try { pw = require('playwright'); }
                catch { pw = require('playwright-core'); }
                const b = await pw.${browser}.launch({ headless: true });
                const page = await b.newPage();
                await page.setContent('<h1>ok</h1>');
                const text = await page.textContent('h1');
                if (text === 'ok') process.stdout.write('ok');
                await b.close();
            })().catch(e => { process.stderr.write(e.message.split('\n')[0]); process.exit(1); });
        "
        local result=""
        if result=$(node -e "$test_script" 2>/tmp/pw-check-$browser.log) && [ "$result" = "ok" ]; then
            ok "$browser: launches and renders correctly"
        else
            err "$browser: failed to launch"
            if [ -s "/tmp/pw-check-$browser.log" ]; then
                err "  $(head -1 /tmp/pw-check-$browser.log)"
            fi
            all_good=false
        fi
    done

    echo ""
    if $all_good; then
        echo -e "${GREEN}All checks passed. Playwright is ready on Fedora.${NC}"
    else
        echo -e "${RED}Some checks failed. Run: ./setup.sh${NC}"
        exit 1
    fi
    ) # end subshell
}

# ── Ensure ~/.local/bin is in PATH ─────────────────────────────
ensure_local_bin_in_path() {
    local local_bin="$HOME/.local/bin"

    # Fish: add to fish_user_paths if not already there
    if command -v fish &>/dev/null; then
        local fish_config="$HOME/.config/fish/config.fish"
        mkdir -p "$(dirname "$fish_config")"
        if ! grep -q 'local/bin' "$fish_config" 2>/dev/null; then
            echo 'fish_add_path -g ~/.local/bin' >> "$fish_config"
        fi
    fi

    # Bash: add to .bashrc if not already in PATH
    local bashrc="$HOME/.bashrc"
    if [ -f "$bashrc" ] && ! grep -q 'local/bin.*PATH\|PATH.*local/bin' "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<'EOF'

# Add ~/.local/bin to PATH
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
EOF
    fi

    # Zsh: add to .zshrc if it exists and not already in PATH
    local zshrc="$HOME/.zshrc"
    if [ -f "$zshrc" ] && ! grep -q 'local/bin.*PATH\|PATH.*local/bin' "$zshrc" 2>/dev/null; then
        cat >> "$zshrc" <<'EOF'

# Add ~/.local/bin to PATH
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
EOF
    fi

    ok "Ensured ~/.local/bin is in PATH"
}

# ── Install wrapper scripts ────────────────────────────────────
install_wrappers() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    info "Installing to ~/.local/bin and shell config..."

    mkdir -p "$HOME/.local/bin"

    # Copy setup script
    cp "$script_dir/setup.sh" "$HOME/.local/bin/playwright-fedora-setup"
    chmod +x "$HOME/.local/bin/playwright-fedora-setup"
    ok "Installed playwright-fedora-setup -> ~/.local/bin/"

    # Ensure ~/.local/bin is in PATH for all shells
    ensure_local_bin_in_path

    # Install fish function
    if command -v fish &>/dev/null; then
        mkdir -p "$HOME/.config/fish/functions"
        cp "$script_dir/shell/pw.fish" "$HOME/.config/fish/functions/pw.fish"
        ok "Installed pw.fish -> ~/.config/fish/functions/"
    fi

    # Install bash function
    local bashrc="$HOME/.bashrc"
    if [ -f "$bashrc" ]; then
        if ! grep -q 'playwright-fedora' "$bashrc" 2>/dev/null; then
            cat >> "$bashrc" <<'BASHEOF'

# Playwright Fedora wrapper (https://github.com/CybLow/playwright-fedora)
if [ -f "$HOME/.local/share/playwright-fedora/pw.bash" ]; then
    source "$HOME/.local/share/playwright-fedora/pw.bash"
fi
BASHEOF
            mkdir -p "$HOME/.local/share/playwright-fedora"
            cp "$script_dir/shell/pw.bash" "$HOME/.local/share/playwright-fedora/pw.bash"
            ok "Installed pw.bash -> ~/.local/share/playwright-fedora/"
        else
            ok "Bash integration already installed"
        fi
    fi

    # Install zsh function
    local zshrc="$HOME/.zshrc"
    if [ -f "$zshrc" ]; then
        if ! grep -q 'playwright-fedora' "$zshrc" 2>/dev/null; then
            cat >> "$zshrc" <<'ZSHEOF'

# Playwright Fedora wrapper (https://github.com/CybLow/playwright-fedora)
if [ -f "$HOME/.local/share/playwright-fedora/pw.bash" ]; then
    source "$HOME/.local/share/playwright-fedora/pw.bash"
fi
ZSHEOF
            ok "Added pw to ~/.zshrc"
        fi
    fi

    echo ""
    ok "Installation complete. Restart your shell or run: source ~/.bashrc"
}

# ── Main ───────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}Playwright Fedora Setup${NC}"
    echo ""

    case "$MODE" in
        full)
            verify_fedora
            install_deps
            install_playwright_npm
            install_browsers
            if [ "$CI_MODE" = false ]; then
                echo ""
                check_installation
            else
                ok "CI mode: skipping browser launch verification (run tests separately)"
            fi
            ;;
        deps)
            verify_fedora
            install_deps
            ;;
        browsers)
            install_browsers
            ;;
        patch)
            patch_webkit_wrappers
            ;;
        check)
            check_installation
            ;;
        install)
            install_wrappers
            ;;
    esac
}

main
