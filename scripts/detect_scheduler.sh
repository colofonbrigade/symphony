#!/bin/sh
# detect_scheduler.sh — report the host system's task scheduler (init system).
# Supports: launchd (macOS), systemd, OpenRC, Upstart, runit, SysV init.
# Usage: ./scripts/detect_scheduler.sh
# Exit codes: 0 success, 1 unrecognised

set -eu

OS="$(uname -s)"

# macOS always uses launchd
if [ "$OS" = "Darwin" ]; then
    echo "Task scheduler: launchd"
    exit 0
fi

# Linux detection
if [ "$OS" = "Linux" ]; then
    # systemd: canonical indicator is /run/systemd/system
    if [ -d /run/systemd/system ]; then
        echo "Task scheduler: systemd"
        exit 0
    fi

    # OpenRC: /run/openrc directory is present when OpenRC is active
    if [ -d /run/openrc ]; then
        echo "Task scheduler: OpenRC"
        exit 0
    fi

    # Upstart: initctl binary present and reports upstart in version string
    if command -v initctl >/dev/null 2>&1; then
        if initctl --version 2>/dev/null | grep -qi upstart; then
            echo "Task scheduler: Upstart"
            exit 0
        fi
    fi

    # runit: PID 1 is runit (void linux, etc.)
    if [ -d /run/runit ]; then
        echo "Task scheduler: runit"
        exit 0
    fi

    # SysV init fallback: /etc/inittab is the classic marker
    if [ -f /etc/inittab ]; then
        echo "Task scheduler: SysV init"
        exit 0
    fi

    # Last resort: read PID 1 comm if /proc is available
    if [ -r /proc/1/comm ]; then
        INIT_NAME="$(cat /proc/1/comm)"
        echo "Task scheduler: ${INIT_NAME}"
        exit 0
    fi

    echo "Task scheduler: unknown (Linux)" >&2
    exit 1
fi

echo "Task scheduler: unknown (OS: ${OS})" >&2
exit 1
