#!/usr/bin/env bash
# Exercise package selection and shell wrappers without a registry or browsers.
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null || { echo 'Node.js is required' >&2; exit 1; }
temp_base="${TMPDIR:-$HOME/.cache/codex-tmp}"
mkdir -p "$temp_base"
test_dir="$(mktemp -d "$temp_base/playwright-resolution.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
original_path="$PATH"
passed=0
failed=0

mkdir -p "$test_dir/bin" "$test_dir/template"
cat > "$test_dir/template/package.json" <<'EOF'
{"name":"playwright","version":"1.64.1","main":"index.js","bin":{"playwright":"cli.js"}}
EOF
cat > "$test_dir/template/cli.js" <<'EOF'
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
if (args[0] === '--version') console.log(`Version ${require('./package.json').version}`);
else if (args[0] === '--args') console.log(JSON.stringify(args.slice(1)));
else if (args[0] === '--require-test') {
  const fromSpec = require('module').createRequire(path.join(process.cwd(), 'spec.js'));
  console.log(JSON.stringify([fromSpec('@playwright/test'), fromSpec('existing-dependency')]));
}
else if (args[0] === 'fail') process.exit(17);
else if (args[0] === 'install') {
  fs.appendFileSync(process.env.TEST_CLI_LOG, JSON.stringify(args) + '\n');
  if (process.env.TEST_FAIL_INSTALL) process.exit(23);
} else throw new Error(`Unexpected CLI invocation: ${args.join(' ')}`);
EOF
cat > "$test_dir/template/index.js" <<'EOF'
const fs = require('fs');
module.exports = Object.fromEntries(['chromium', 'firefox', 'webkit'].map(engine => [engine, {
  async launch() {
    if (process.env.TEST_FAIL_ENGINE === engine) throw new Error('fixture launch failure');
    fs.appendFileSync(process.env.TEST_LAUNCH_LOG, engine + '\n');
    return {
      async newPage() { return { async setContent() {}, async textContent() { return 'ok'; } }; },
      async close() {}
    };
  }
}]));
EOF

# These stubs guard the network boundary. Module resolution and CLI execution
# still use real Node processes and the public setup.sh entry points.
cat > "$test_dir/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = 'root -g' ]; then
    printf '%s\n' "$TEST_GLOBAL_ROOT"
elif [ "$1" = install ] && [ "$2" = --prefix ]; then
    printf 'install\n' >> "$TEST_NPM_LOG"
    mkdir -p "$3/node_modules/playwright"
    cp -a "$TEST_PACKAGE_TEMPLATE/." "$3/node_modules/playwright/"
else
    echo "Unexpected npm invocation: $*" >&2
    exit 90
fi
EOF
cat > "$test_dir/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf 'npx\n' >> "$TEST_NPX_LOG"
echo 'Unexpected npx invocation: package selection must not download' >&2
exit 91
EOF
cat > "$test_dir/bin/playwright" <<'EOF'
#!/usr/bin/env bash
echo 'Version 9.9.9 (wrong CLI from PATH)'
exit 92
EOF
cat > "$test_dir/bin/playwright-fedora-setup" <<'EOF'
#!/usr/bin/env bash
exec bash "$TEST_REPO_DIR/setup.sh" "$@"
EOF
chmod +x "$test_dir/bin/"*

new_case() {
    case_dir="$(mktemp -d "$test_dir/case.XXXXXX")"
    mkdir -p "$case_dir/clean" "$case_dir/home" "$case_dir/browsers/webkit-fixture"
    export HOME="$case_dir/home"
    export PATH="$test_dir/bin:$original_path"
    export NODE_PATH=''
    export PLAYWRIGHT_NPM_DIR="$case_dir/managed"
    export PLAYWRIGHT_BROWSERS_PATH="$case_dir/browsers"
    export PLAYWRIGHT_COMPAT_DIR="$case_dir/compat"
    export TEST_GLOBAL_ROOT="$case_dir/global/node_modules"
    export TEST_PACKAGE_TEMPLATE="$test_dir/template"
    export TEST_NPM_LOG="$case_dir/npm.log"
    export TEST_NPX_LOG="$case_dir/npx.log"
    export TEST_CLI_LOG="$case_dir/cli.log"
    export TEST_LAUNCH_LOG="$case_dir/launch.log"
    export TEST_REPO_DIR="$repo_dir"
    unset TEST_FAIL_ENGINE TEST_FAIL_INSTALL
    cd "$case_dir/clean" || return 1
}

package_at() {
    local modules_dir="$1" version="${2:-1.64.1}"
    mkdir -p "$modules_dir/playwright"
    cp -a "$test_dir/template/." "$modules_dir/playwright/"
    node -e 'const fs=require("fs"), p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p)); j.version=process.argv[2]; fs.writeFileSync(p,JSON.stringify(j));' \
        "$modules_dir/playwright/package.json" "$version"
}

expect_exit() {
    local expected="$1" actual
    shift
    "$@" > "$case_dir/output" 2>&1
    actual=$?
    if [ "$actual" -ne "$expected" ]; then
        printf 'Expected exit %s, got %s\n' "$expected" "$actual" >&2
        cat "$case_dir/output" >&2
        return 1
    fi
}

no_npx() { [ ! -e "$TEST_NPX_LOG" ]; }

missing_package() (
    new_case || exit 1
    expect_exit 1 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q -- '--npm' "$case_dir/output" && no_npx
)
managed_cli() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    expect_exit 0 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q 'Version 1.64.1' "$case_dir/output" && no_npx
)
local_cli() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    package_at "$case_dir/clean/node_modules" 1.63.0
    mkdir nested
    cd nested || exit 1
    expect_exit 0 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q 'Version 1.63.0' "$case_dir/output" && no_npx
)
pnpm_project_cli() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    local store="$case_dir/clean/node_modules/.pnpm"
    local test_package="$store/@playwright+test@1.63.0/node_modules/@playwright/test"
    package_at "$store/playwright@1.63.0/node_modules" 1.63.0
    mkdir -p "$test_package" "$case_dir/clean/node_modules/@playwright"
    printf '%s\n' '{"name":"@playwright/test","version":"1.63.0","main":"index.js","dependencies":{"playwright":"1.63.0"}}' > "$test_package/package.json"
    printf '%s\n' 'module.exports = require("playwright");' > "$test_package/index.js"
    ln -s "$store/playwright@1.63.0/node_modules/playwright" "$store/@playwright+test@1.63.0/node_modules/playwright"
    ln -s "$test_package" "$case_dir/clean/node_modules/@playwright/test"
    expect_exit 0 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q 'Version 1.63.0' "$case_dir/output" && no_npx
)
managed_test_import() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    local test_package="$PLAYWRIGHT_NPM_DIR/node_modules/@playwright/test"
    export NODE_PATH="$case_dir/existing modules"
    mkdir -p "$test_package" "$NODE_PATH/existing-dependency"
    printf '%s\n' '{"name":"@playwright/test","version":"1.64.1","main":"index.js"}' > "$test_package/package.json"
    printf '%s\n' 'module.exports = "managed test";' > "$test_package/index.js"
    printf '%s\n' 'module.exports = "existing module";' > "$NODE_PATH/existing-dependency/index.js"
    expect_exit 0 bash "$repo_dir/setup.sh" --run --require-test || exit 1
    grep -Fq '["managed test","existing module"]' "$case_dir/output" && no_npx
)
custom_node_path() (
    new_case || exit 1
    export NODE_PATH="$case_dir/custom modules"
    package_at "$NODE_PATH" 1.62.0
    expect_exit 0 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q 'Version 1.62.0' "$case_dir/output" || exit 1
    expect_exit 0 bash "$repo_dir/setup.sh" --check || exit 1
    [ "$(wc -l < "$TEST_LAUNCH_LOG")" -eq 3 ] && no_npx
)
global_cli() (
    new_case || exit 1
    package_at "$TEST_GLOBAL_ROOT" 1.61.0
    expect_exit 0 bash "$repo_dir/setup.sh" --run --version || exit 1
    grep -q 'Version 1.61.0' "$case_dir/output" && no_npx
)
cli_arguments() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    expect_exit 0 bash "$repo_dir/setup.sh" --run --args 'one argument' --help '' || exit 1
    grep -Fq '["one argument","--help",""]' "$case_dir/output" && no_npx
)
npm_install() (
    new_case || exit 1
    expect_exit 0 bash "$repo_dir/setup.sh" --npm || exit 1
    [ "$(wc -l < "$TEST_NPM_LOG")" -eq 1 ] || exit 1
    expect_exit 0 bash "$repo_dir/setup.sh" --npm || exit 1
    [ "$(wc -l < "$TEST_NPM_LOG")" -eq 1 ] || exit 1
    grep -q '1.64.1' "$case_dir/output" && no_npx
)
check_missing() (
    new_case || exit 1
    expect_exit 1 bash "$repo_dir/setup.sh" --check || exit 1
    grep -q -- '--npm' "$case_dir/output" && [ ! -e "$TEST_LAUNCH_LOG" ] && no_npx
)
check_launches() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    expect_exit 0 bash "$repo_dir/setup.sh" --check || exit 1
    [ "$(wc -l < "$TEST_LAUNCH_LOG")" -eq 3 ] || exit 1
    export TEST_FAIL_ENGINE=firefox
    expect_exit 1 bash "$repo_dir/setup.sh" --check || exit 1
    grep -q 'fixture launch failure' "$case_dir/output" && no_npx
)
browsers_missing() (
    new_case || exit 1
    expect_exit 1 bash "$repo_dir/setup.sh" --browsers || exit 1
    grep -q -- '--npm' "$case_dir/output" && no_npx
)
browsers_cli() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    expect_exit 0 bash "$repo_dir/setup.sh" --browsers || exit 1
    grep -Fq '["install","chromium","firefox","webkit"]' "$TEST_CLI_LOG" && no_npx
)

# Invoke pw in the shell itself: command substitution would conceal the zsh
# environment leak by running the function in a child process.
shell_wrapper() (
    local shell_name="$1"
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    export NODE_PATH='/existing/one:/existing/two'
    export LD_LIBRARY_PATH='/existing/libraries'
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS='original'
    export TEST_WRAPPER="$repo_dir/shell/pw.bash"
    export TEST_WRAPPER_OUTPUT="$case_dir/version"
    expect_exit 0 "$shell_name" -c '
        source "$TEST_WRAPPER"
        before_path="$PATH"; before_node="$NODE_PATH"
        before_ld="$LD_LIBRARY_PATH"; before_skip="$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS"
        pw --version > "$TEST_WRAPPER_OUTPUT" || exit 1
        [ "$PATH" = "$before_path" ] && [ "$NODE_PATH" = "$before_node" ] || exit 2
        [ "$LD_LIBRARY_PATH" = "$before_ld" ] && [ "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS" = "$before_skip" ] || exit 3
        pw fail > /dev/null; result=$?
        [ "$result" -eq 17 ] || exit 4
        [ "$PATH" = "$before_path" ] && [ "$NODE_PATH" = "$before_node" ] || exit 5
        [ "$LD_LIBRARY_PATH" = "$before_ld" ] && [ "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS" = "$before_skip" ] || exit 6
    ' || exit 1
    grep -q 'Version 1.64.1' "$TEST_WRAPPER_OUTPUT" && no_npx
)
fish_wrapper() (
    new_case || exit 1
    package_at "$PLAYWRIGHT_NPM_DIR/node_modules"
    export NODE_PATH='/existing/one:/existing/two'
    export LD_LIBRARY_PATH='/existing/libraries'
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS='original'
    export TEST_WRAPPER="$repo_dir/shell/pw.fish"
    export TEST_WRAPPER_OUTPUT="$case_dir/version"
    expect_exit 0 fish --no-config -c '
        source "$TEST_WRAPPER"
        set before_path "$PATH"; set before_node "$NODE_PATH"
        set before_ld "$LD_LIBRARY_PATH"; set before_skip "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS"
        pw --version > "$TEST_WRAPPER_OUTPUT"; or exit 1
        test "$PATH" = "$before_path"; and test "$NODE_PATH" = "$before_node"; or exit 2
        test "$LD_LIBRARY_PATH" = "$before_ld"; and test "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS" = "$before_skip"; or exit 3
        pw fail > /dev/null; set result $status
        test "$result" -eq 17; or exit 4
        test "$PATH" = "$before_path"; and test "$NODE_PATH" = "$before_node"; or exit 5
        test "$LD_LIBRARY_PATH" = "$before_ld"; and test "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS" = "$before_skip"; or exit 6
    ' || exit 1
    grep -q 'Version 1.64.1' "$TEST_WRAPPER_OUTPUT" && no_npx
)

t() {
    local name="$1"
    shift
    if "$@"; then
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$name"
        failed=$((failed + 1))
    fi
}

t 'missing package fails without downloading' missing_package
t 'managed package CLI wins over an unrelated executable in PATH' managed_cli
t 'project version wins over managed version from a nested directory' local_cli
t 'pnpm project test runner selects its pinned Playwright dependency' pnpm_project_cli
t 'project code can import managed test runner and existing NODE_PATH modules' managed_test_import
t 'existing NODE_PATH works for CLI and all engine checks' custom_node_path
t 'npm global package is a fallback' global_cli
t 'CLI arguments preserve spaces, flags and empty values' cli_arguments
t 'managed npm installation is idempotent' npm_install
t 'missing package check fails before engine launches' check_missing
t 'engine checks use the resolved package and preserve failure status' check_launches
t 'browser install requires a resolvable package' browsers_missing
t 'browser install uses the resolved CLI' browsers_cli
t 'Bash wrapper restores environment and preserves CLI status' shell_wrapper bash
if command -v zsh >/dev/null; then
    t 'zsh wrapper restores environment and preserves CLI status' shell_wrapper zsh
else
    printf 'SKIP zsh is unavailable\n'
fi
if command -v fish >/dev/null; then
    t 'fish wrapper restores environment and preserves CLI status' fish_wrapper
else
    printf 'SKIP fish is unavailable\n'
fi

printf '\nPassed: %s; failed: %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
