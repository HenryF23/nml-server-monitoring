#!/usr/bin/env bash

# Shared implementation for host-package cleanup scripts.
# Callers define CLEANUP_NAME, CLEANUP_DESCRIPTION, PACKAGES, UNITS, PROCESSES,
# and PATHS.

CLEANUP_DRY_RUN=0
CLEANUP_ASSUME_YES=0
CLEANUP_FOUND=0

cleanup_info() { printf '[INFO] %s\n' "$*"; }
cleanup_ok()   { printf '[ OK ] %s\n' "$*"; }
cleanup_warn() { printf '[WARN] %s\n' "$*" >&2; }
cleanup_die()  { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

cleanup_usage() {
    cat <<EOF
Usage:
  sudo ./${CLEANUP_NAME} [--dry-run] [--yes]

${CLEANUP_DESCRIPTION}

Options:
  --dry-run  Show detected host resources and planned commands; change nothing.
  --yes      Skip the confirmation prompt.
  -h, --help Show this help.

Docker containers, images, networks, volumes, and repository files are never
removed by this script.
EOF
}

cleanup_init() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) CLEANUP_DRY_RUN=1 ;;
            --yes|-y) CLEANUP_ASSUME_YES=1 ;;
            -h|--help) cleanup_usage; exit 0 ;;
            *) cleanup_usage >&2; cleanup_die "Unknown option: $1" ;;
        esac
        shift
    done

    if (( ! CLEANUP_DRY_RUN )) && [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        cleanup_die "Run with sudo/root."
    fi
    command -v dpkg-query >/dev/null 2>&1 || \
        cleanup_die "Only Debian/Ubuntu systems using dpkg are supported."
    command -v apt-get >/dev/null 2>&1 || \
        cleanup_die "Only Debian/Ubuntu systems using apt are supported."
}

package_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

unit_exists() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local state
    state="$(systemctl show "$1" -p LoadState --value 2>/dev/null || true)"
    [[ -n "$state" && "$state" != "not-found" ]]
}

process_is_containerized() {
    local pid="$1"
    grep -Eiq '(docker|containerd|kubepods|libpod|podman|lxc)' \
        "/proc/$pid/cgroup" 2>/dev/null && return 0
    [[ -e "/proc/$pid/root/.dockerenv" ]]
}

host_pids_for() {
    local name="$1" proc pid executable
    for proc in /proc/[0-9]*; do
        [[ -L "$proc/exe" ]] || continue
        pid="${proc##*/}"
        executable="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        [[ "${executable##*/}" == "$name" ]] || continue
        process_is_containerized "$pid" || printf '%s\n' "$pid"
    done
}

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

run_command() {
    if (( CLEANUP_DRY_RUN )); then
        printf '[DRY RUN]\n'
        print_command "$@"
        return 0
    fi
    "$@"
}

show_plan() {
    local item pid
    printf '\n%s\n' "$CLEANUP_DESCRIPTION"
    echo "Detected host resources:"

    for item in "${PACKAGES[@]}"; do
        if package_installed "$item"; then
            printf '  package  %s\n' "$item"
            CLEANUP_FOUND=1
        fi
    done
    for item in "${UNITS[@]}"; do
        if unit_exists "$item"; then
            printf '  service  %s\n' "$item"
            CLEANUP_FOUND=1
        fi
    done
    for item in "${PROCESSES[@]}"; do
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            printf '  process  %s (PID %s)\n' "$item" "$pid"
            CLEANUP_FOUND=1
        done < <(host_pids_for "$item")
    done
    for item in "${PATHS[@]}"; do
        if [[ -e "$item" || -L "$item" ]]; then
            printf '  path     %s\n' "$item"
            CLEANUP_FOUND=1
        fi
    done

    (( CLEANUP_FOUND )) || echo "  none"
    echo
    echo "Docker resources: preserved"
}

stop_processes() {
    local name pid attempt
    local pids=() alive=()

    for name in "${PROCESSES[@]}"; do
        pids=()
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && pids+=("$pid")
        done < <(host_pids_for "$name")
        ((${#pids[@]})) || continue

        cleanup_info "Stopping host process $name (${pids[*]})"
        if (( CLEANUP_DRY_RUN )); then
            run_command kill -TERM "${pids[@]}"
            continue
        fi

        kill -TERM "${pids[@]}" 2>/dev/null || true
        for attempt in 1 2 3 4 5; do
            sleep 1
            alive=()
            for pid in "${pids[@]}"; do
                [[ -d "/proc/$pid" ]] && alive+=("$pid")
            done
            pids=("${alive[@]}")
            ((${#pids[@]})) || break
        done
        ((${#pids[@]})) && kill -KILL "${pids[@]}" 2>/dev/null || true
    done
}

confirm_cleanup() {
    (( CLEANUP_DRY_RUN || CLEANUP_ASSUME_YES )) && return 0
    local answer=""
    printf '\nType REMOVE to continue: '
    read -r answer
    [[ "$answer" == "REMOVE" ]] || cleanup_die "Cancelled; nothing was changed."
}

stop_services() {
    command -v systemctl >/dev/null 2>&1 || {
        cleanup_warn "systemctl is unavailable; skipping service operations."
        return 0
    }

    local unit
    for unit in "${UNITS[@]}"; do
        unit_exists "$unit" || continue
        cleanup_info "Stopping and disabling $unit"
        if ! run_command systemctl disable --now "$unit"; then
            cleanup_warn "Could not fully stop/disable $unit; continuing cleanup."
        fi
    done
}

purge_packages() {
    local package
    local installed=()
    for package in "${PACKAGES[@]}"; do
        package_installed "$package" && installed+=("$package")
    done

    if ((${#installed[@]} == 0)); then
        cleanup_info "No matching APT packages are installed."
        return 0
    fi

    cleanup_info "Purging APT packages: ${installed[*]}"
    run_command env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}"
}

remove_paths() {
    local path
    for path in "${PATHS[@]}"; do
        [[ -e "$path" || -L "$path" ]] || continue
        cleanup_info "Removing $path"
        if ! run_command rm -rf --one-file-system -- "$path"; then
            cleanup_warn "Could not remove $path"
        fi
    done
}

reload_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 0
    run_command systemctl daemon-reload || cleanup_warn "systemd daemon-reload failed."
    run_command systemctl reset-failed || true
}

run_cleanup() {
    show_plan
    if (( ! CLEANUP_FOUND )); then
        cleanup_ok "Nothing to clean. Docker resources were preserved."
        return 0
    fi
    confirm_cleanup
    stop_services
    stop_processes
    purge_packages
    remove_paths
    reload_systemd

    if (( CLEANUP_DRY_RUN )); then
        cleanup_ok "Dry run complete; nothing was changed."
    else
        cleanup_ok "Host cleanup complete. Docker resources were preserved."
    fi
}
