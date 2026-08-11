#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

CLEANUP_NAME="cleanup-grafana.sh"
CLEANUP_DESCRIPTION="Remove host-installed Grafana services, packages, configuration, data, logs, and APT repository files."

PACKAGES=(
    grafana
    grafana-enterprise
)

UNITS=(
    grafana-server.service
)

PROCESSES=(
    grafana
    grafana-server
)

PATHS=(
    /etc/grafana
    /var/lib/grafana
    /var/log/grafana
    /var/cache/grafana
    /usr/share/grafana
    /opt/grafana
    /usr/local/grafana
    /usr/local/bin/grafana
    /usr/local/bin/grafana-cli
    /usr/local/bin/grafana-server
    /etc/default/grafana-server
    /etc/init.d/grafana-server
    /etc/systemd/system/grafana-server.service
    /lib/systemd/system/grafana-server.service
    /usr/lib/systemd/system/grafana-server.service
    /etc/apt/sources.list.d/grafana.list
    /etc/apt/keyrings/grafana.asc
    /etc/apt/keyrings/grafana.gpg
    /usr/share/keyrings/grafana.key
    /usr/share/keyrings/grafana-archive-keyring.gpg
)

source ./cleanup-lib.sh
cleanup_init "$@"
run_cleanup
