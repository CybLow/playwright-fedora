#!/usr/bin/env bash
# Test native Playwright CLI commands on Fedora
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_script="${PLAYWRIGHT_SETUP_SCRIPT:-$script_dir/../setup.sh}"
mkdir -p "${TMPDIR:-$HOME/.cache/codex-tmp}"
test_tmp=$(mktemp -d "${TMPDIR:-$HOME/.cache/codex-tmp}/pw-cli.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT

export LD_LIBRARY_PATH="${HOME}/.local/lib/playwright-compat/lib64:${HOME}/.local/lib/playwright-compat/icu:${HOME}/.local/lib/playwright-compat${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# Exercise Playwright's dependency validation, including the Fedora 44 libav check.
unset PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS

PASS="\033[32mPASS\033[0m"
FAIL="\033[31mFAIL\033[0m"
passed=0; failed=0

t() {
    local name="$1"; shift
    if "$@" >"$test_tmp/output.log" 2>&1; then
        echo -e "  $PASS  $name"; ((passed++))
    else
        echo -e "  $FAIL  $name"; ((failed++))
        cat "$test_tmp/output.log"
    fi
}

playwright() {
    bash "$setup_script" --run "$@"
}

echo ""
echo -e "\033[1m=== Playwright CLI Commands ===\033[0m"

t "resolved playwright --version" playwright --version

t "screenshot (chromium)" \
    playwright screenshot --browser=chromium 'data:text/html,<h1>Chromium</h1>' "$test_tmp/cr.png"

t "screenshot (firefox)" \
    playwright screenshot --browser=firefox 'data:text/html,<h1>Firefox</h1>' "$test_tmp/ff.png"

t "screenshot (webkit)" \
    playwright screenshot --browser=webkit 'data:text/html,<h1>WebKit</h1>' "$test_tmp/wk.png"

t "screenshot --viewport-size" \
    playwright screenshot --browser=chromium --viewport-size=375,812 'data:text/html,<h1>Mobile</h1>' "$test_tmp/mobile.png"

t "screenshot --full-page" \
    playwright screenshot --browser=chromium --full-page 'data:text/html,<body style="height:3000px"><h1>Tall</h1></body>' "$test_tmp/full.png"

t "pdf generation" \
    playwright pdf 'data:text/html,<h1>PDF</h1>' "$test_tmp/page.pdf"

t "clear-cache" playwright clear-cache

t "install --dry-run" playwright install --dry-run

echo ""
echo -e "\033[1m=== Summary ===\033[0m"
echo -e "  Passed: $passed"
echo -e "  Failed: $failed"

[ "$failed" -eq 0 ] && echo -e "\n\033[32mAll CLI tests passed.\033[0m" || { echo -e "\n\033[31m$failed test(s) failed.\033[0m"; exit 1; }
