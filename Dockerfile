ARG FEDORA_VERSION=43
FROM fedora:${FEDORA_VERSION}

# System deps needed for setup (cmake, gcc, nasm for libjpeg build)
RUN dnf install -y \
        nodejs npm git cmake gcc gcc-c++ nasm \
        xorg-x11-server-Xvfb dbus-x11 mesa-dri-drivers \
        sudo curl binutils zstd libatomic \
        mesa-libEGL mesa-libGLES mesa-libgbm libwayland-server \
    && dnf clean all

# Create non-root user (Chromium sandboxing behaves differently as root)
RUN useradd -m -s /bin/bash pwuser \
    && echo "pwuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/pwuser

USER pwuser
WORKDIR /home/pwuser/playwright-fedora

# Copy project files
COPY --chown=pwuser:pwuser setup.sh ./setup.sh
COPY --chown=pwuser:pwuser shell/ ./shell/
COPY --chown=pwuser:pwuser tests/ ./tests/
RUN chmod +x setup.sh tests/*.sh

# Run full setup (deps + compat libs + browsers + verify)
RUN bash setup.sh --ci

# Install playwright as a local package so tests can require() it
RUN mkdir -p /home/pwuser/test-run \
    && cd /home/pwuser/test-run \
    && npm init -y --silent \
    && npm install playwright --silent 2>&1 | tail -3

# Copy test files into the npm project so require('playwright') works
RUN cp /home/pwuser/playwright-fedora/tests/test-browsers.js /home/pwuser/test-run/ \
    && cp /home/pwuser/playwright-fedora/tests/test-cli.sh /home/pwuser/test-run/

ENV LD_LIBRARY_PATH="/home/pwuser/.local/lib/playwright-compat/lib64:/home/pwuser/.local/lib/playwright-compat/icu:/home/pwuser/.local/lib/playwright-compat:/usr/lib64" \
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    MESA_GL_VERSION_OVERRIDE=3.3

# Run all tests (headless-only since no display in Docker; use xvfb for CLI)
# IMPORTANT: Run with --shm-size=1g (Chromium crashes with Docker's default 64MB)
CMD ["bash", "-c", "\
    echo '=== Browser API Tests (headless) ===' && \
    cd /home/pwuser/test-run && node test-browsers.js --headless-only && \
    echo '' && \
    echo '=== CLI Tests (xvfb) ===' && \
    xvfb-run --auto-servernum -- bash test-cli.sh \
"]
