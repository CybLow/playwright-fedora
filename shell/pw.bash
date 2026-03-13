# pw -- Playwright wrapper for Fedora (bash/zsh)
# https://github.com/CybLow/playwright-fedora
#
# Source this file in your .bashrc or .zshrc:
#   source ~/.local/share/playwright-fedora/pw.bash

pw() {
    local _pw_old_ldpath="${LD_LIBRARY_PATH:-}"
    local _pw_old_skip="${PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS:-}"
    export LD_LIBRARY_PATH="$HOME/.local/lib/playwright-compat/lib64:$HOME/.local/lib/playwright-compat/icu:$HOME/.local/lib/playwright-compat:/usr/lib64:${LD_LIBRARY_PATH:-}"
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

    # Ensure env is restored on return (even on early exit)
    trap 'export LD_LIBRARY_PATH="$_pw_old_ldpath"; [ -z "$_pw_old_skip" ] && unset PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS || export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="$_pw_old_skip"; trap - RETURN' RETURN

    case "${1:-}" in
        "")
            echo "pw -- Playwright wrapper for Fedora"
            echo ""
            echo "Usage:"
            echo "  pw test [args...]        Run Playwright tests"
            echo "  pw codegen [url]         Open code generator"
            echo "  pw show-report           Open last HTML report"
            echo "  pw install [browser]     Install/update browsers (auto-patches WebKit)"
            echo "  pw setup                 Full Fedora setup (system deps + browsers)"
            echo "  pw check                 Verify browsers launch correctly"
            echo "  pw ui                    Open Playwright UI mode"
            echo "  pw trace <file>          Open trace viewer"
            echo "  pw <cmd> [args...]       Pass through to npx playwright"
            ;;
        setup)
            shift; playwright-fedora-setup "$@"
            ;;
        check)
            playwright-fedora-setup --check
            ;;
        install)
            shift
            npx playwright install "$@"
            __pw_patch_webkit
            echo ""
            playwright-fedora-setup --check
            ;;
        ui)
            shift; npx playwright test --ui "$@"
            ;;
        *)
            npx playwright "$@"
            ;;
    esac
}

__pw_patch_webkit() {
    local compat_lib_dir="$HOME/.local/lib/playwright-compat/lib64"
    if [ ! -d "$compat_lib_dir" ]; then
        echo "pw: compat libjpeg not found at $compat_lib_dir — run: pw setup"
        return 1
    fi

    local patched=0
    for wrapper in "$HOME/.cache/ms-playwright"/webkit-*/minibrowser-{gtk,wpe}/MiniBrowser; do
        [ -f "$wrapper" ] || continue
        grep -q 'playwright-compat' "$wrapper" 2>/dev/null && continue
        if grep -q 'export LD_LIBRARY_PATH=' "$wrapper"; then
            sed -i 's|export LD_LIBRARY_PATH="|export LD_LIBRARY_PATH="${HOME}/.local/lib/playwright-compat/lib64:${HOME}/.local/lib/playwright-compat/icu:|' "$wrapper"
            patched=$((patched + 1))
        fi
    done

    if [ "$patched" -gt 0 ]; then
        echo "pw: patched $patched WebKit wrapper(s) for Fedora compat"
    fi
}
