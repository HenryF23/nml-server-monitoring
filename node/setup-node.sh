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
  sudo ./setup-node.sh --central-ip TAILSCALE_IP [--name NAME] [--cpu-only]

The central IP is saved after the first run. GPU monitoring is the default.
Use --cpu-only only on a server without an NVIDIA GPU.
EOF
}

is_tailscale_ipv4() {
    local ip="$1" a b c d extra
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && \
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a == 100 && b >= 64 && b <= 127 && c <= 255 && d <= 255 ))
}

SERVER_NAME=""
CENTRAL_TAILSCALE_IP=""
CPU_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|--central-ip)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            case "$1" in
                --name) SERVER_NAME="$2" ;;
                --central-ip) CENTRAL_TAILSCALE_IP="$2" ;;
            esac
            shift 2
            ;;
        --cpu-only) CPU_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."
command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."
command -v tailscale >/dev/null 2>&1 || die "Tailscale is not installed."

TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
is_tailscale_ipv4 "$TAILSCALE_IP" || \
    die "This server is not connected to Tailscale. Run 'tailscale up' first."

if (( ! CPU_ONLY )); then
    gpu_error="If this is intentionally a CPU-only server, rerun with --cpu-only."
    command -v nvidia-smi >/dev/null 2>&1 || \
        die "No NVIDIA driver or GPU was found. $gpu_error"
    nvidia-smi >/dev/null 2>&1 || \
        die "The NVIDIA GPU is installed but cannot be accessed. $gpu_error"
    docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"' || \
        die "NVIDIA Container Toolkit is not configured for Docker. $gpu_error"
else
    info "CPU-only mode selected; GPU metrics will be disabled."
fi

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

SERVER_NAME="${SERVER_NAME:-$(read_env SERVER_NAME)}"
SERVER_NAME="${SERVER_NAME:-$(hostname -s)}"
CENTRAL_TAILSCALE_IP="${CENTRAL_TAILSCALE_IP:-$(read_env CENTRAL_TAILSCALE_IP)}"

[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Invalid server name '$SERVER_NAME'."
is_tailscale_ipv4 "$CENTRAL_TAILSCALE_IP" || \
    die "Provide the central server's Tailscale IPv4 with --central-ip (100.64.0.0/10)."

[[ -f .env ]] || cp .env.example .env
set_env SERVER_NAME "$SERVER_NAME"
set_env TAILSCALE_IP "$TAILSCALE_IP"
set_env CENTRAL_TAILSCALE_IP "$CENTRAL_TAILSCALE_IP"
chmod 600 .env

tmp_config="$(mktemp prometheus/agent.yml.tmp.XXXXXX)"
if (( CPU_ONLY )); then
    sed -e '/^  # GPU_SCRAPE_JOB$/d' \
        -e "s|__CENTRAL_TAILSCALE_IP__|${CENTRAL_TAILSCALE_IP}|" \
        -e 's|__GPU_ENABLED__|false|' \
        prometheus/agent.yml.template >"$tmp_config"
else
    sed '/^  # GPU_SCRAPE_JOB$/r prometheus/gpu-scrape.yml' \
        prometheus/agent.yml.template |
        sed -e '/^  # GPU_SCRAPE_JOB$/d' \
            -e "s|__CENTRAL_TAILSCALE_IP__|${CENTRAL_TAILSCALE_IP}|" \
            -e 's|__GPU_ENABLED__|true|' >"$tmp_config"
fi
chown 65534:65534 "$tmp_config"
chmod 444 "$tmp_config"
mv "$tmp_config" prometheus/agent.yml

info "Using local Tailscale address $TAILSCALE_IP; no Docker bridge network will be created."
info "Pulling and validating the monitoring containers..."
docker compose config >/dev/null
if (( CPU_ONLY )); then
    docker compose pull
else
    docker compose --profile gpu pull
fi
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus-agent \
    check config /etc/prometheus/agent.yml >/dev/null

if command -v curl >/dev/null 2>&1 && \
   ! curl -fsS --max-time 5 "http://${CENTRAL_TAILSCALE_IP}:9090/-/ready" >/dev/null; then
    warn "Central Prometheus is not reachable at ${CENTRAL_TAILSCALE_IP}:9090."
    warn "Check that setup-central.sh is running and that Tailscale access rules allow TCP 9090."
fi

if (( CPU_ONLY )); then
    docker compose --profile gpu stop dcgm-exporter >/dev/null 2>&1 || true
    docker compose --profile gpu rm -f dcgm-exporter >/dev/null 2>&1 || true
    info "Starting host and container monitoring..."
    docker compose up -d --remove-orphans
else
    info "Starting host, container, and GPU monitoring..."
    docker compose --profile gpu up -d --remove-orphans
fi

echo
docker compose --profile gpu ps
echo
ok "'$SERVER_NAME' is configured to send metrics to ${CENTRAL_TAILSCALE_IP} over Tailscale."
echo "Node IP : ${TAILSCALE_IP}"
echo "Mode    : $( (( CPU_ONLY )) && echo CPU-only || echo GPU )"
echo "Verify  : ./verify-node.sh"
