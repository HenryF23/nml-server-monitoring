#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."

random_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
    fi
}

read_env() {
    local key="$1"
    grep -m1 -E "^${key}=" .env 2>/dev/null | cut -d= -f2- || true
}

set_env() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp .env.tmp.XXXXXX)"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { print key "=" value; found=1; next }
        { print }
        END { if (!found) print key "=" value }
    ' .env >"$tmp"
    mv "$tmp" .env
}

if [[ ! -f .env ]]; then
    cp .env.example .env
    info "Created central/.env."
else
    info "Preserving existing central/.env settings."
fi

grafana_password="$(read_env GRAFANA_ADMIN_PASSWORD)"
if [[ -z "$grafana_password" || "$grafana_password" == "CHANGE_ME" ]]; then
    set_env GRAFANA_ADMIN_PASSWORD "$(random_hex 24)"
    ok "Generated a Grafana administrator password."
fi

monitoring_token="$(read_env MONITORING_TOKEN)"
if [[ -z "$monitoring_token" || "$monitoring_token" == "CHANGE_ME" ]]; then
    set_env MONITORING_TOKEN "$(random_hex 32)"
    ok "Generated a remote-write authentication token."
fi
chmod 600 .env

info "Validating Docker Compose configuration..."
docker compose config >/dev/null
ok "Compose configuration is valid."

info "Pulling container images..."
docker compose pull

info "Starting Prometheus, the authenticated gateway, and Grafana..."
docker compose up -d

echo
docker compose ps
echo

grafana_port="$(read_env GRAFANA_PORT)"
grafana_port="${grafana_port:-3000}"
prometheus_port="$(read_env PROMETHEUS_PORT)"
prometheus_port="${prometheus_port:-9090}"
remote_write_port="$(read_env REMOTE_WRITE_PORT)"
remote_write_port="${remote_write_port:-9091}"
admin_user="$(read_env GRAFANA_ADMIN_USER)"
admin_user="${admin_user:-admin}"
monitoring_token="$(read_env MONITORING_TOKEN)"
central_host="$(hostname -f 2>/dev/null || hostname -s)"

ok "Central monitoring is ready."
echo
echo "Grafana       : http://<monitoring-server>:${grafana_port}"
echo "Prometheus    : http://127.0.0.1:${prometheus_port}"
echo "Grafana user  : ${admin_user}"
echo
echo "Show the generated Grafana password later with:"
echo "  grep '^GRAFANA_ADMIN_PASSWORD=' .env"
echo
echo "Run this once on each monitored server after copying the node/ directory:"
echo "  sudo ./setup-node.sh --central-url 'http://${central_host}:${remote_write_port}/api/v1/write' --token '${monitoring_token}'"
echo
echo "Use the central server's private IP or VPN hostname if '${central_host}'"
echo "is not resolvable from monitored servers. Keep TCP ${remote_write_port} private."
