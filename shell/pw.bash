# pw -- Playwright wrapper for Fedora (bash/zsh)
# https://github.com/CybLow/playwright-fedora
#
# Source this file in your .bashrc or .zshrc:
#   source ~/.local/share/playwright-fedora/pw.bash

pw() (
    # A subshell scopes the environment in both bash and zsh, including failures.
    local _pw_compat_dir="${PLAYWRIGHT_COMPAT_DIR:-$HOME/.local/lib/playwright-compat}"
    export LD_LIBRARY_PATH="${_pw_compat_dir}/lib64:${_pw_compat_dir}/icu:${_pw_compat_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

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
            echo "  pw <cmd> [args...]       Pass through to the installed Playwright CLI"
            ;;
        setup)
            shift; playwright-fedora-setup "$@"
            ;;
        check)
            playwright-fedora-setup --check
            ;;
        install)
            shift
            if [ ! -d "${_pw_compat_dir}/lib64" ]; then
                echo "pw: compat libjpeg not found at ${_pw_compat_dir}/lib64 — run: pw setup" >&2
                return 1
            fi
            playwright-fedora-setup --run install "$@" || return $?
            playwright-fedora-setup --patch || return $?
            echo ""
            playwright-fedora-setup --check
            ;;
        ui)
            shift; playwright-fedora-setup --run test --ui "$@"
            ;;
        *)
            playwright-fedora-setup --run "$@"
            ;;
    esac
)
