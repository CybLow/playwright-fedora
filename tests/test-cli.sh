#!/usr/bin/env bash
# Test native Playwright CLI commands on Fedora
set -uo pipefail

export LD_LIBRARY_PATH="${HOME}/.local/lib/playwright-compat/lib64:${HOME}/.local/lib/playwright-compat/icu:${HOME}/.local/lib/playwright-compat:/usr/lib64:${LD_LIBRARY_PATH:-}"
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

PASS="\033[32mPASS\033[0m"
FAIL="\033[31mFAIL\033[0m"
passed=0; failed=0

t() {
    local name="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
        echo -e "  $PASS  $name"; ((passed++))
    else
        echo -e "  $FAIL  $name"; ((failed++))
    fi
}

echo ""
echo -e "\033[1m=== Playwright CLI Commands ===\033[0m"

t "npx playwright --version" "npx playwright --version"

t "screenshot (chromium)" \
    "npx playwright screenshot --browser=chromium 'data:text/html,<h1>Chromium</h1>' /tmp/pw-cli-cr.png"

t "screenshot (firefox)" \
    "npx playwright screenshot --browser=firefox 'data:text/html,<h1>Firefox</h1>' /tmp/pw-cli-ff.png"

t "screenshot (webkit)" \
    "npx playwright screenshot --browser=webkit 'data:text/html,<h1>WebKit</h1>' /tmp/pw-cli-wk.png"

t "screenshot --viewport-size" \
    "npx playwright screenshot --browser=chromium --viewport-size='375,812' 'data:text/html,<h1>Mobile</h1>' /tmp/pw-cli-mobile.png"

t "screenshot --full-page" \
    "npx playwright screenshot --browser=chromium --full-page 'data:text/html,<body style=\"height:3000px\"><h1>Tall</h1></body>' /tmp/pw-cli-full.png"

t "pdf generation" \
    "npx playwright pdf 'data:text/html,<h1>PDF</h1>' /tmp/pw-cli.pdf"

t "clear-cache" "npx playwright clear-cache"

t "install --dry-run" "npx playwright install --dry-run"

echo ""
echo -e "\033[1m=== Summary ===\033[0m"
echo -e "  Passed: $passed"
echo -e "  Failed: $failed"

[ "$failed" -eq 0 ] && echo -e "\n\033[32mAll CLI tests passed.\033[0m" || { echo -e "\n\033[31m$failed test(s) failed.\033[0m"; exit 1; }
