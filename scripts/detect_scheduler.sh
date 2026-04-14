#!/bin/sh
set -eu

# Detect the host task scheduler and print its name.
# Exits 0 on success, 1 when the scheduler cannot be identified.

detect_scheduler() {
    # macOS always uses launchd
    case "$(uname -s)" in
        Darwin)
            echo "Task scheduler: launchd"
            return 0
            ;;
    esac

    # Linux: probe well-known runtime markers in preference order.
    if [ -d /run/systemd/system ]; then
        echo "Task scheduler: systemd"
        return 0
    fi

    if [ -d /run/openrc ]; then
        echo "Task scheduler: OpenRC"
        return 0
    fi

    if [ -d /run/runit ]; then
        echo "Task scheduler: runit"
        return 0
    fi

    if [ -f /etc/inittab ]; then
        echo "Task scheduler: SysV init"
        return 0
    fi

    if initctl --version >/dev/null 2>&1; then
        echo "Task scheduler: Upstart"
        return 0
    fi

    # Last resort: read the name of PID 1
    if [ -r /proc/1/comm ]; then
        comm=$(cat /proc/1/comm)
        echo "Task scheduler: $comm"
        return 0
    fi

    echo "Task scheduler: unknown" >&2
    return 1
}

detect_scheduler
