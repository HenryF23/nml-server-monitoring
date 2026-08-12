#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./setup-central.sh [--bind-address IPV4 | --auto-bind]

Automatic binding prefers this server's Tailscale IPv4 address and falls back
to all IPv4 interfaces when Tailscale is unavailable. --bind-address selects
and saves one address explicitly; --auto-bind returns to automatic selection.
EOF
}

is_ipv4() {
    local ip="$1" a b c d extra
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && \
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

is_tailscale_ipv4() {
    local ip="$1" a b c d extra
    is_ipv4 "$ip" || return 1
    IFS=. read -r a b c d extra <<<"$ip"
    (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 ))
}

BIND_ADDRESS=""
BIND_MODE=""
BIND_OPTION_SET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bind-address)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            (( BIND_OPTION_SET == 0 )) || \
                die "Use either --bind-address or --auto-bind, not both."
            BIND_ADDRESS="$2"
            BIND_MODE="manual"
            BIND_OPTION_SET=1
            shift 2
            ;;
        --auto-bind)
            (( BIND_OPTION_SET == 0 )) || \
                die "Use either --bind-address or --auto-bind, not both."
            BIND_MODE="auto"
            BIND_OPTION_SET=1
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

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

BIND_MODE="${BIND_MODE:-$(read_env CENTRAL_BIND_MODE)}"
BIND_MODE="${BIND_MODE:-auto}"
[[ "$BIND_MODE" == "auto" || "$BIND_MODE" == "manual" ]] || \
    die "Invalid CENTRAL_BIND_MODE '$BIND_MODE'. Use auto or manual."

if [[ "$BIND_MODE" == "manual" ]]; then
    BIND_ADDRESS="${BIND_ADDRESS:-$(read_env CENTRAL_BIND_ADDRESS)}"
    [[ -n "$BIND_ADDRESS" ]] || \
        die "Manual binding requires --bind-address IPV4."
else
    BIND_ADDRESS=""
    if command -v tailscale >/dev/null 2>&1; then
        BIND_ADDRESS="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    fi
    if is_tailscale_ipv4 "$BIND_ADDRESS"; then
        info "Detected local Tailscale address $BIND_ADDRESS."
    else
        BIND_ADDRESS="0.0.0.0"
        warn "Tailscale is unavailable; falling back to all host IPv4 interfaces."
    fi
fi

is_ipv4 "$BIND_ADDRESS" || die "Invalid --bind-address '$BIND_ADDRESS'."
set_env CENTRAL_BIND_MODE "$BIND_MODE"
set_env CENTRAL_BIND_ADDRESS "$BIND_ADDRESS"
if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
    set_env GRAFANA_PROMETHEUS_URL "http://127.0.0.1:9090"
else
    set_env GRAFANA_PROMETHEUS_URL "http://${BIND_ADDRESS}:9090"
fi

grafana_password="$(read_env GRAFANA_ADMIN_PASSWORD)"
if [[ -z "$grafana_password" || "$grafana_password" == "CHANGE_ME" ]]; then
    set_env GRAFANA_ADMIN_PASSWORD "$(random_hex 24)"
    ok "Generated a Grafana administrator password."
fi
chmod 600 .env

info "Binding central services to $BIND_ADDRESS; no Docker bridge network will be created."
if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
    warn "Prometheus and Grafana will listen on every host IPv4 interface."
    warn "Allow TCP 9090/3000 only from trusted LAN or Tailscale clients."
fi
docker compose config >/dev/null
ok "Compose configuration is valid."

info "Pulling container images..."
docker compose pull

info "Validating Prometheus configuration and capacity rules..."
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus \
    check config /etc/prometheus/prometheus.yml >/dev/null

info "Starting Prometheus and Grafana..."
docker compose up -d --remove-orphans --force-recreate

echo
docker compose ps
echo

grafana_port="$(read_env GRAFANA_PORT)"
grafana_port="${grafana_port:-3000}"
admin_user="$(read_env GRAFANA_ADMIN_USER)"
admin_user="${admin_user:-admin}"
central_host="$(hostname -s)"
if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
    display_host="$central_host"
else
    display_host="$BIND_ADDRESS"
fi

ok "Central monitoring is ready."
echo
echo "Grafana      : http://${display_host}:${grafana_port}"
echo "Prometheus   : http://${display_host}:9090"
echo "Grafana user : ${admin_user}"
echo
echo "Show the generated Grafana password later with:"
echo "  grep '^GRAFANA_ADMIN_PASSWORD=' .env"
echo
echo "Run this once from node/ on each monitored server:"
if [[ "$BIND_MODE" == "manual" && "$BIND_ADDRESS" != "0.0.0.0" ]]; then
    echo "  sudo ./setup-node.sh --central-ip '${BIND_ADDRESS}'"
else
    echo "  sudo ./setup-node.sh --central-host '${central_host}'"
fi
echo
echo "IP fallback (use any address that reaches this server):"
echo "  sudo ./setup-node.sh --central-ip '<central-ip>'"
echo
echo "The central server can monitor itself with the same command."
