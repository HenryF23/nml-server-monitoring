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
  sudo ./setup-node.sh --central-host HOSTNAME [--name NAME] [--cpu-only]
  sudo ./setup-node.sh --central-ip IPV4 [--name NAME] [--cpu-only]

The central host or IP is saved after the first run. HOSTNAME may use LAN DNS,
/etc/hosts, or Tailscale MagicDNS. GPU monitoring is the default. Use
--cpu-only only on a server without an NVIDIA GPU.
EOF
}

is_ipv4() {
    local ip="$1" a b c d extra
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && \
       "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

resolve_central_host() {
    local host="$1" candidate
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || \
        die "Invalid central hostname '$host'."
    command -v getent >/dev/null 2>&1 || \
        die "getent is required to resolve --central-host."

    while read -r candidate _; do
        if is_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <({ getent ahostsv4 "$host" || getent hosts "$host"; } 2>/dev/null || true)

    die "Central host '$host' did not resolve to an IPv4 address. Check DNS or /etc/hosts."
}

SERVER_NAME=""
CENTRAL_IP=""
CENTRAL_HOST=""
CPU_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|--central-ip|--central-host)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            case "$1" in
                --name) SERVER_NAME="$2" ;;
                --central-ip) CENTRAL_IP="$2" ;;
                --central-host) CENTRAL_HOST="$2" ;;
            esac
            shift 2
            ;;
        --cpu-only) CPU_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "$CENTRAL_IP" || -z "$CENTRAL_HOST" ]] || \
    die "Use either --central-host or --central-ip, not both."

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."
command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."

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

if [[ -z "$CENTRAL_HOST" && -z "$CENTRAL_IP" ]]; then
    CENTRAL_HOST="$(read_env CENTRAL_HOST)"
    if [[ -z "$CENTRAL_HOST" ]]; then
        CENTRAL_IP="$(read_env CENTRAL_IP)"
    fi
fi

if [[ -n "$CENTRAL_HOST" ]]; then
    CENTRAL_IP="$(resolve_central_host "$CENTRAL_HOST")"
    info "Resolved central host '$CENTRAL_HOST' to $CENTRAL_IP."
fi

[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Invalid server name '$SERVER_NAME'."
is_ipv4 "$CENTRAL_IP" || \
    die "Provide --central-host HOSTNAME or --central-ip with a valid IPv4 address."

[[ -f .env ]] || cp .env.example .env
set_env SERVER_NAME "$SERVER_NAME"
set_env CENTRAL_HOST "$CENTRAL_HOST"
set_env CENTRAL_IP "$CENTRAL_IP"
chmod 600 .env

tmp_config="$(mktemp prometheus/agent.yml.tmp.XXXXXX)"
if (( CPU_ONLY )); then
    sed -e '/^  # GPU_SCRAPE_JOB$/d' \
        -e "s|__CENTRAL_IP__|${CENTRAL_IP}|" \
        -e 's|__GPU_ENABLED__|false|' \
        prometheus/agent.yml.template >"$tmp_config"
else
    sed '/^  # GPU_SCRAPE_JOB$/r prometheus/gpu-scrape.yml' \
        prometheus/agent.yml.template |
        sed -e '/^  # GPU_SCRAPE_JOB$/d' \
            -e "s|__CENTRAL_IP__|${CENTRAL_IP}|" \
            -e 's|__GPU_ENABLED__|true|' >"$tmp_config"
fi
chown 65534:65534 "$tmp_config"
chmod 444 "$tmp_config"
mv "$tmp_config" prometheus/agent.yml

info "Using Docker host networking; no Docker bridge network will be created."
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
   ! curl -fsS --max-time 5 "http://${CENTRAL_IP}:9090/-/ready" >/dev/null; then
    warn "Central Prometheus is not reachable at ${CENTRAL_IP}:9090."
    warn "Check setup-central.sh, routing, and firewall access to TCP 9090."
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
ok "'$SERVER_NAME' is configured to send metrics to central Prometheus."
if [[ -n "$CENTRAL_HOST" ]]; then
    echo "Central : ${CENTRAL_HOST} (${CENTRAL_IP})"
else
    echo "Central : ${CENTRAL_IP}"
fi
echo "Mode    : $( (( CPU_ONLY )) && echo CPU-only || echo GPU )"
echo "Verify  : ./verify-node.sh"
