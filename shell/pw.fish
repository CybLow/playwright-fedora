# pw -- Playwright wrapper for Fedora
# https://github.com/CybLow/playwright-fedora

function pw --description "Playwright wrapper for Fedora"
    set -lx LD_LIBRARY_PATH $HOME/.local/lib/playwright-compat/lib64 $HOME/.local/lib/playwright-compat/icu $HOME/.local/lib/playwright-compat /usr/lib64 $LD_LIBRARY_PATH
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
        echo "  pw <cmd> [args...]       Pass through to npx playwright"
        return 0
    end

    switch $argv[1]
        case setup
            playwright-fedora-setup $argv[2..]

        case check
            playwright-fedora-setup --check

        case install
            npx playwright install $argv[2..]
            __pw_patch_webkit
            echo ""
            playwright-fedora-setup --check

        case ui
            npx playwright test --ui $argv[2..]

        case '*'
            npx playwright $argv
    end
end

function __pw_patch_webkit
    set -l compat_lib_dir "$HOME/.local/lib/playwright-compat/lib64"
    if not test -d $compat_lib_dir
        echo "pw: compat libjpeg not found at $compat_lib_dir — run: pw setup"
        return 1
    end

    set -l patched 0
    for wrapper in $HOME/.cache/ms-playwright/webkit-*/minibrowser-{gtk,wpe}/MiniBrowser
        test -f $wrapper; or continue
        grep -q 'playwright-compat' $wrapper 2>/dev/null; and continue
        if grep -q 'export LD_LIBRARY_PATH=' $wrapper
            sed -i 's|export LD_LIBRARY_PATH="|export LD_LIBRARY_PATH="${HOME}/.local/lib/playwright-compat/lib64:${HOME}/.local/lib/playwright-compat/icu:|' $wrapper
            set patched (math $patched + 1)
        end
    end

    if test $patched -gt 0
        echo "pw: patched $patched WebKit wrapper(s) for Fedora compat"
    end
end
