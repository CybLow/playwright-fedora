#!/usr/bin/env bash
# Exercise the real package installer with DNF/RPM at the network boundary.
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${TMPDIR:-$HOME/.cache/codex-tmp}"
test_dir=$(mktemp -d "${TMPDIR:-$HOME/.cache/codex-tmp}/pw-codecs.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
passed=0
failed=0

new_case() {
    # Load functions without executing the installer's final main call.
    source <(sed '$d' "$repo_dir/setup.sh")
    set +e
    case_dir=$(mktemp -d "$test_dir/case.XXXXXX")
    dnf_count=0
    sudo_count=0
    primary_status=0
    fallback_status=0
    release_status=0
    release_installed=true
    test_uid=0
    fixture_rpm_fedora=42
    fixture_rpm_arch=x86_64
}

id() { printf '%s\n' "$test_uid"; }
sudo() { sudo_count=$((sudo_count + 1)); "$@"; }
rpm() {
    if [ "$1" = -q ]; then
        "$release_installed"
    elif [ "$2" = '%{fedora}' ]; then
        printf '%s\n' "$fixture_rpm_fedora"
    elif [ "$2" = '%{_arch}' ]; then
        printf '%s\n' "$fixture_rpm_arch"
    else
        return 91
    fi
}
dnf() {
    dnf_count=$((dnf_count + 1))
    printf '%s\n' "$@" > "$case_dir/dnf.$dnf_count"
    if [[ "$*" = *rpmfusion-free-release-*.rpm* ]]; then
        return "$release_status"
    elif [[ "$*" = *--setopt=rpmfusion-free.baseurl=* ]]; then
        return "$fallback_status"
    fi
    return "$primary_status"
}

expect_arg() { grep -Fxq -- "$2" "$case_dir/dnf.$1"; }
normal_mirrors() (
    new_case
    install_h264_packages || exit 1
    [ "$dnf_count" -eq 1 ] &&
        expect_arg 1 libavcodec-freeworld &&
        expect_arg 1 x264-libs
)
direct_fallback() (
    new_case
    primary_status=1
    install_h264_packages || exit 1
    [ "$dnf_count" -eq 2 ] || exit 1
    for arg in --refresh \
        --setopt=rpmfusion-free.metalink= \
        --setopt=rpmfusion-free.baseurl=https://download1.rpmfusion.org/free/fedora/releases/42/Everything/x86_64/os/ \
        --setopt=rpmfusion-free.gpgcheck=1 \
        --setopt=rpmfusion-free-updates.metalink= \
        --setopt=rpmfusion-free-updates.baseurl=https://download1.rpmfusion.org/free/fedora/updates/42/x86_64/ \
        --setopt=rpmfusion-free-updates.gpgcheck=1 \
        libavcodec-freeworld x264-libs gstreamer1-plugin-libav; do
        expect_arg 2 "$arg" || exit 1
    done
    ! grep -Eq 'nogpgcheck|gpgcheck=0|sslverify=0|skip-unavailable' "$case_dir/dnf.2"
)
nonroot_fallback() (
    new_case
    test_uid=1000
    primary_status=1
    install_h264_packages || exit 1
    [ "$dnf_count" -eq 2 ] && [ "$sudo_count" -eq 2 ]
)
release_and_arch() (
    new_case
    fixture_rpm_fedora=43
    fixture_rpm_arch=aarch64
    primary_status=1
    install_h264_packages || exit 1
    expect_arg 2 --setopt=rpmfusion-free.baseurl=https://download1.rpmfusion.org/free/fedora/releases/43/Everything/aarch64/os/ &&
        expect_arg 2 --setopt=rpmfusion-free-updates.baseurl=https://download1.rpmfusion.org/free/fedora/updates/43/aarch64/
)
fallback_failure() (
    new_case
    primary_status=1
    fallback_status=47
    install_h264_packages
    result=$?
    [ "$result" -eq 47 ] && [ "$dnf_count" -eq 2 ]
)
release_failure() (
    new_case
    release_installed=false
    release_status=23
    install_h264_packages
    result=$?
    [ "$result" -eq 23 ] && [ "$dnf_count" -eq 1 ]
)
enable_then_retry() (
    new_case
    release_installed=false
    test_uid=1000
    primary_status=1
    install_h264_packages || exit 1
    [ "$dnf_count" -eq 3 ] && [ "$sudo_count" -eq 3 ] &&
        expect_arg 1 https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-42.noarch.rpm &&
        expect_arg 3 --setopt=rpmfusion-free.gpgcheck=1
)

t() {
    local name="$1"
    shift
    if "$@" > "$test_dir/output" 2>&1; then
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$name"
        cat "$test_dir/output"
        failed=$((failed + 1))
    fi
}

t 'working mirrors need no retry' normal_mirrors
t 'failed mirrors fall back to the primary HTTPS repositories with GPG checks' direct_fallback
t 'nonroot retries use sudo' nonroot_fallback
t 'fallback matches the Fedora version and architecture' release_and_arch
t 'fallback failure remains a setup failure' fallback_failure
t 'release package failure stops installation' release_failure
t 'new repository setup can use the same fallback' enable_then_retry
printf '\nPassed: %s; failed: %s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
