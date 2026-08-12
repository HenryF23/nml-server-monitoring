#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."
command -v tailscale >/dev/null 2>&1 || die "Tailscale is not installed."

tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1)"
[[ "$tailscale_ip" =~ ^100\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || \
    die "This server is not connected to Tailscale. Run 'tailscale up' first."
second_octet="${BASH_REMATCH[1]}"
(( second_octet >= 64 && second_octet <= 127 )) || \
    die "Unexpected Tailscale IPv4 address: $tailscale_ip"

random_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
    fi
}

read_env() {
    local key="$1"
    [[ -f .env ]] || return 0
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

set_env TAILSCALE_IP "$tailscale_ip"

grafana_password="$(read_env GRAFANA_ADMIN_PASSWORD)"
if [[ -z "$grafana_password" || "$grafana_password" == "CHANGE_ME" ]]; then
    set_env GRAFANA_ADMIN_PASSWORD "$(random_hex 24)"
    ok "Generated a Grafana administrator password."
fi
chmod 600 .env

info "Using Tailscale address $tailscale_ip; no Docker bridge network will be created."
docker compose config >/dev/null
ok "Compose configuration is valid."

info "Pulling container images..."
docker compose pull

info "Validating Prometheus configuration and capacity rules..."
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus \
    check config /etc/prometheus/prometheus.yml >/dev/null

info "Starting Prometheus and Grafana on the Tailscale interface..."
docker compose up -d --remove-orphans --force-recreate

echo
docker compose ps
echo

grafana_port="$(read_env GRAFANA_PORT)"
grafana_port="${grafana_port:-3000}"
admin_user="$(read_env GRAFANA_ADMIN_USER)"
admin_user="${admin_user:-admin}"
central_host="$(hostname -s)"

ok "Central monitoring is ready on Tailscale."
echo
echo "Grafana      : http://${tailscale_ip}:${grafana_port}"
echo "Prometheus   : http://${tailscale_ip}:9090"
echo "Grafana user : ${admin_user}"
echo
echo "Show the generated Grafana password later with:"
echo "  grep '^GRAFANA_ADMIN_PASSWORD=' .env"
echo
echo "Run this once from node/ on each monitored server (Tailscale MagicDNS):"
echo "  sudo ./setup-node.sh --central-host '${central_host}'"
echo
echo "IP fallback:"
echo "  sudo ./setup-node.sh --central-ip '${tailscale_ip}'"
echo
echo "The central server can monitor itself with the same command."
