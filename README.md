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

## Upstream PR

Native Fedora support has been submitted upstream: [microsoft/playwright#39661](https://github.com/microsoft/playwright/pull/39661). Once merged, `npx playwright install-deps` and `npx playwright install` will work natively on Fedora without this project.

Until then, this project provides a standalone solution.

## What it does

1. **Installs system dependencies** via `dnf` (including GTK 4) and enables **RPM Fusion Free** for WebKit H.264 support (`libavcodec-freeworld` and `x264-libs`, alongside Fedora's `gstreamer1-plugin-libav`).
2. **Downloads Ubuntu 24.04's `libjpeg-turbo8` package** — Fedora's version exports `LIBJPEG_6.2` symbols but Playwright's WebKit needs `LIBJPEG_8.0`
3. **Downloads ICU 74 compat libraries** from Ubuntu 24.04 — Fedora ships ICU 75-77+ which are not ABI-compatible with Playwright's WebKit (built on Ubuntu 24.04)
4. **Creates libjxl soversion symlinks** — Fedora has `libjxl.so.0.11`, Playwright expects `libjxl.so.0.8`
5. **Patches WebKit MiniBrowser wrappers** to load compat libraries (the wrappers overwrite `LD_LIBRARY_PATH`, ignoring the parent env)
6. **Installs the Playwright npm packages** into `~/.local/lib/playwright-npm` when no existing installation is found
7. **Installs shell wrappers** (`pw` command for fish/bash/zsh)

The compat libraries are installed to `~/.local/lib/playwright-compat/` and do **not** affect system libraries. No compiler toolchain (cmake, gcc, nasm) is required.

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
pw setup --npm               # Install only the Playwright npm packages
pw <anything>                # Run the resolved Playwright CLI
```

> **Important:** Always use `pw install` instead of `npx playwright install` to ensure WebKit wrappers are automatically patched after browser downloads.

## Package manager support

Full setup installs `playwright` and `@playwright/test` into the private
`~/.local/lib/playwright-npm` prefix when needed. This npm installation needs no
`sudo` and leaves npm's global prefix unchanged. To install only the packages:

```bash
pw setup --npm
# From a checkout, before the pw wrapper is installed:
bash setup.sh --npm
```

You can also keep Playwright in each project with your preferred package manager:

```bash
npm install --save-dev @playwright/test
# or:
bun add --dev @playwright/test
# or:
pnpm add --save-dev @playwright/test
```

The CLI and browser verification resolve the same package: the current
project's installation first, then the private prefix, an existing `NODE_PATH`,
and npm's global installation. A project's pinned version therefore takes
precedence over the shared installation. Commands use that package's CLI
directly; they never ask `npx` to download another version. If no package is
found, run `pw setup --npm` before `pw install` or `pw check`.

After installing or updating a project's Playwright version, run `pw install`
from that project to download its matching browsers and auto-patch WebKit.
`pw check` returns a nonzero exit status if verification fails. The shell
wrappers scope their environment changes to the command, including in zsh.

## How the WebKit fix works

Playwright ships pre-built browser binaries compiled on Ubuntu 24.04. On Fedora, several libraries are either missing or ABI-incompatible:

### libjpeg-turbo (JPEG8 ABI)

WebKit links against `libjpeg.so.8` with `LIBJPEG_8.0` ELF version symbols (Ubuntu builds libjpeg-turbo with `-DWITH_JPEG8=1`). Fedora's libjpeg-turbo exports `LIBJPEG_6.2` symbols. The soname matches but the version symbol check fails:

```
/lib64/libjpeg.so.8: version `LIBJPEG_8.0' not found
```

**Fix:** Download Ubuntu 24.04's `libjpeg-turbo8` package (which provides `libjpeg.so.8` with `LIBJPEG_8.0` symbols) into `~/.local/lib/playwright-compat/lib64/`.

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

### Fedora 44: `gstreamer1.0-libav` / H.264

Playwright's `gstreamer1.0-libav` error means its dependency checker could not
find `libx264`. Having `gstreamer1` or Fedora's libav plugin installed is not
enough: WebKit also needs H.264 codecs. Setup enables RPM Fusion **Free** and
installs `libavcodec-freeworld` and `x264-libs`; RPM Fusion Nonfree is not needed.
These are system codec packages, separate from the private JPEG/ICU libraries.

The wrappers leave the system library directories to the dynamic linker so
RPM Fusion's codec library takes precedence over Fedora's limited version.
Setup also refreshes the current user's GStreamer decoder cache.

If RPM Fusion's mirror metadata is unavailable or inconsistent, setup retries
the codec transaction against RPM Fusion's primary HTTPS server. Package GPG
checks remain enabled, and this fallback does not edit your repository files.

To update an existing installation, run the one-liner installer again, restart
your shell, then run `pw setup`. From a checkout:

```bash
git pull
bash setup.sh --install
# Restart your shell to load the updated wrapper, then:
pw setup
pw check
```

For direct `npx` / `pnpm exec` commands, provide the private compat libraries:

```bash
export LD_LIBRARY_PATH="$HOME/.local/lib/playwright-compat/lib64:$HOME/.local/lib/playwright-compat/icu:$HOME/.local/lib/playwright-compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
pnpm exec playwright test
```

Do not explicitly prepend `/usr/lib64` to `LD_LIBRARY_PATH`: it overrides the
system's preferred codec library. The test suite checks dependency validation
and actual WebKit H.264 playback without skipping host requirements.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS` | Set to `1` by `pw` wrapper to skip Playwright's Ubuntu-only dependency checker |
| `PLAYWRIGHT_COMPAT_DIR` | Override compat lib location (default: `~/.local/lib/playwright-compat`) |
| `PLAYWRIGHT_BROWSERS_PATH` | Override browser cache location (default: `~/.cache/ms-playwright`) |
| `PLAYWRIGHT_NPM_DIR` | Override the private npm prefix (default: `~/.local/lib/playwright-npm`) |

## Supported Fedora versions

| Version | Status |
|---------|--------|
| Fedora 44 | Tested in CI (default Docker image) |
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

## Tested features

**Browser API tests** across Chromium, Firefox, and WebKit:

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
- H.264 video playback (WebKit)
- File download handling
- Console message capture
- Request/response events
- Local storage
- iframe handling
- Keyboard input
- Trace recording (Chromium)
- HAR recording (Chromium)

**9 CLI tests:**

- Resolved Playwright CLI `--version`
- Screenshot (chromium, firefox, webkit)
- Screenshot with viewport / full-page
- PDF generation
- Cache clearing
- Install dry-run

The container also checks the GStreamer H.264 decoder and `libx264` availability,
and runs headed browser tests under Xvfb. It verifies setup from an empty
directory with `NODE_PATH` unset, then runs the API and CLI suites against the
private installation without installing another local copy of Playwright.

The regression suites run without browser downloads:

```bash
bash tests/test-resolution.sh
bash tests/test-codecs.sh
```

They cover missing packages, matching package/CLI versions, project-local
precedence, existing `NODE_PATH`, global fallback, and shell environment
restoration, plus codec mirror fallback and installation failure propagation.
CI runs both suites before building the Fedora images.

## License

MIT
