# pw -- Playwright wrapper for Fedora
# https://github.com/CybLow/playwright-fedora

function pw --description "Playwright wrapper for Fedora"
    set -l _pw_compat_dir $HOME/.local/lib/playwright-compat
    test -n "$PLAYWRIGHT_COMPAT_DIR"; and set _pw_compat_dir $PLAYWRIGHT_COMPAT_DIR
    set -lx LD_LIBRARY_PATH $_pw_compat_dir/lib64 $_pw_compat_dir/icu $_pw_compat_dir $LD_LIBRARY_PATH
    set -lx PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS 1

    if test (count $argv) -eq 0
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
        return 0
    end

    switch $argv[1]
        case setup
            playwright-fedora-setup $argv[2..]

        case check
            playwright-fedora-setup --check

        case install
            if not test -d $_pw_compat_dir/lib64
                echo "pw: compat libjpeg not found at $_pw_compat_dir/lib64 — run: pw setup" >&2
                return 1
            end
            playwright-fedora-setup --run install $argv[2..]; or return $status
            playwright-fedora-setup --patch; or return $status
            echo ""
            playwright-fedora-setup --check

        case ui
            playwright-fedora-setup --run test --ui $argv[2..]

        case '*'
            playwright-fedora-setup --run $argv
    end
end
