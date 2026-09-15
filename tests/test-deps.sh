#!/usr/bin/env bash
# Check the H.264 support behind Playwright's gstreamer1.0-libav error (issue #1).
set -euo pipefail

echo '=== GStreamer dependency checks ==='
gst-inspect-1.0 avdec_h264 >/dev/null

# Playwright checks for libx264 as a proxy for Ubuntu's GStreamer libav package.
# Avoid grep -q with pipefail: an early reader exit can SIGPIPE ldconfig.
if ! /sbin/ldconfig -p | grep -F 'libx264.so'; then
    echo 'FAIL: libx264 is missing from the linker cache' >&2
    exit 1
fi
echo 'PASS: GStreamer can decode H.264 and Playwright can find libx264'
