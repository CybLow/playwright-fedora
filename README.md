# playwright-fedora

Run [Playwright](https://playwright.dev) on Fedora Linux with **all 3 browser engines** (Chromium, Firefox, WebKit) — fully working, headless and headed.

Playwright officially supports Debian/Ubuntu only. On Fedora, `npx playwright install-deps` fails and WebKit crashes due to ABI incompatibilities. This project fixes that.

## Quick start

```bash
# One-liner install (wrappers only)
curl -fsSL https://raw.githubusercontent.com/CybLow/playwright-fedora/main/install.sh | bash

# Restart your shell, then run full setup
pw setup

# Verify
pw check
```

Or manually:

```bash
git clone https://github.com/CybLow/playwright-fedora.git
cd playwright-fedora
bash setup.sh          # Full setup (system deps + compat libs + browsers + verify)
bash setup.sh --install   # Install pw wrapper to your shell
```

## What it does

1. **Installs system dependencies** via `dnf` (Chromium, Firefox, WebKit runtime libs including mesa-libGLES, mesa-libEGL, libavif, libatomic, gstreamer, etc.)
2. **Builds a compat `libjpeg-turbo`** from source with `-DWITH_JPEG8=1` — Fedora's version exports `LIBJPEG_6.2` symbols but Playwright's WebKit needs `LIBJPEG_8.0`
3. **Downloads ICU 74 compat libraries** from Ubuntu 24.04 — Fedora ships ICU 75-77+ which are not ABI-compatible with Playwright's WebKit (built on Ubuntu 24.04)
4. **Creates libjxl soversion symlinks** — Fedora has `libjxl.so.0.11`, Playwright expects `libjxl.so.0.8`
5. **Patches WebKit MiniBrowser wrappers** to load compat libraries (the wrappers overwrite `LD_LIBRARY_PATH`, ignoring the parent env)
6. **Installs shell wrappers** (`pw` command for fish/bash/zsh)

The compat libraries are installed to `~/.local/lib/playwright-compat/` and do **not** affect system libraries.

## Usage

```bash
pw test                      # Run Playwright tests
pw test --browser chromium   # Specific browser
pw codegen https://example.com  # Code generator
pw screenshot https://example.com /tmp/shot.png
pw pdf https://example.com /tmp/page.pdf
pw ui                        # Playwright UI mode
pw install                   # Install/update browsers (auto-patches WebKit)
pw check                     # Verify all browsers work
pw <anything>                # Passes through to npx playwright
```

> **Important:** Always use `pw install` instead of `npx playwright install` to ensure WebKit wrappers are automatically patched after browser downloads.

## Package manager support

Works with any Node.js package manager:

```bash
# npm (default)
npm install -g playwright @playwright/test

# bun
bun install -g playwright @playwright/test

# pnpm
pnpm add -g playwright @playwright/test
```

After installing Playwright, always run `pw install` (not `npx playwright install`) to auto-patch WebKit.

## How the WebKit fix works

Playwright ships pre-built browser binaries compiled on Ubuntu 24.04. On Fedora, several libraries are either missing or ABI-incompatible:

### libjpeg-turbo (JPEG8 ABI)

WebKit links against `libjpeg.so.8` with `LIBJPEG_8.0` ELF version symbols (Ubuntu builds libjpeg-turbo with `-DWITH_JPEG8=1`). Fedora's libjpeg-turbo exports `LIBJPEG_6.2` symbols. The soname matches but the version symbol check fails:

```
/lib64/libjpeg.so.8: version `LIBJPEG_8.0' not found
```

**Fix:** Build libjpeg-turbo from source with `-DWITH_JPEG8=1` into `~/.local/lib/playwright-compat/lib64/`.

### ICU (International Components for Unicode)

Playwright's WebKit links against ICU 74 (`libicudata.so.74`, `libicui18n.so.74`, `libicuuc.so.74`). Fedora 43 ships ICU 77, which is **not** ABI-compatible (ICU changes symbol names across major versions like `ucnv_open_74`).

**Fix:** Download Ubuntu 24.04's `libicu74` package and extract the libraries into `~/.local/lib/playwright-compat/icu/`.

### libjxl (JPEG XL)

Fedora has `libjxl.so.0.11`, but Playwright expects `libjxl.so.0.8`.

**Fix:** Create a symlink from the system library to the expected soname.

### WebKit MiniBrowser wrappers

Playwright's WebKit MiniBrowser shell wrappers **overwrite** `LD_LIBRARY_PATH` entirely with their own lib directories, ignoring any parent environment:

```bash
export LD_LIBRARY_PATH="${MYDIR}/lib:${MYDIR}/sys/lib"
```

**Fix:** Patch these wrappers to **prepend** the compat lib paths:

```bash
export LD_LIBRARY_PATH="${HOME}/.local/lib/playwright-compat/lib64:${HOME}/.local/lib/playwright-compat/icu:${MYDIR}/lib:${MYDIR}/sys/lib"
```

All compat libraries are scoped to the Playwright process tree only — other applications continue using the system libraries.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS` | Set to `1` by `pw` wrapper to skip Playwright's Ubuntu-only dependency checker |
| `PLAYWRIGHT_COMPAT_DIR` | Override compat lib location (default: `~/.local/lib/playwright-compat`) |
| `PLAYWRIGHT_BROWSERS_PATH` | Override browser cache location (default: `~/.cache/ms-playwright`) |

## Supported Fedora versions

| Version | Status |
|---------|--------|
| Fedora 43 | Tested in CI |
| Fedora 42 | Tested in CI |
| Fedora 41 | Tested in CI |
| Fedora 40 | Should work (EOL) |
| Fedora 39 | Should work (EOL) |

## Docker / CI

```bash
docker build -t playwright-fedora .
docker run --rm --shm-size=1g playwright-fedora
```

The `--shm-size=1g` flag is **required** — Chromium crashes with Docker's default 64MB shared memory.

Use `ARG FEDORA_VERSION` to test specific versions:

```bash
docker build --build-arg FEDORA_VERSION=42 -t playwright-fedora:42 .
```

## Tested features (70 pass)

**61 browser API tests** across Chromium, Firefox, and WebKit:

- Launch headless / headed
- Navigation, title, content
- JavaScript evaluation
- DOM manipulation (fill, click, type)
- Screenshots (PNG buffer, full page, viewport)
- PDF generation (Chromium)
- Multiple pages / tabs
- Context isolation (cookies)
- Network interception (route + fulfill)
- Dynamic content (waitForSelector)
- Locator API (getByRole, getByText)
- Viewport / device emulation
- Geolocation emulation
- Video recording
- File download handling
- Console message capture
- Request/response events
- Local storage
- iframe handling
- Keyboard input
- Trace recording (Chromium)
- HAR recording (Chromium)

**9 CLI tests:**

- `npx playwright --version`
- Screenshot (chromium, firefox, webkit)
- Screenshot with viewport / full-page
- PDF generation
- Cache clearing
- Install dry-run

## License

MIT
