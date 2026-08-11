#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  sudo ./setup-node.sh --central-url URL --token TOKEN [--name NAME] [--cpu-only]

The URL and token are saved. After the first run, use:
  sudo ./setup-node.sh

GPU monitoring is the default. Use --cpu-only only on a server without a GPU.
EOF
}

SERVER_NAME=""
REMOTE_WRITE_URL=""
MONITORING_TOKEN=""
CPU_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|--central-url|--token)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            case "$1" in
                --name) SERVER_NAME="$2" ;;
                --central-url) REMOTE_WRITE_URL="$2" ;;
                --token) MONITORING_TOKEN="$2" ;;
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
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-$(read_env REMOTE_WRITE_URL)}"
if [[ -z "$MONITORING_TOKEN" && -f .monitoring-token ]]; then
    MONITORING_TOKEN="$(<.monitoring-token)"
fi

[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Invalid server name '$SERVER_NAME'."
[[ "$REMOTE_WRITE_URL" =~ ^https?://[^[:space:]]+$ && "$REMOTE_WRITE_URL" != *\"* ]] || \
    die "Provide --central-url, for example http://10.0.0.10:9091/api/v1/write"
[[ "$MONITORING_TOKEN" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || \
    die "Provide --token with the token printed by setup-central.sh."

[[ -f .env ]] || cp .env.example .env
set_env SERVER_NAME "$SERVER_NAME"
set_env REMOTE_WRITE_URL "$REMOTE_WRITE_URL"
chmod 600 .env

printf '%s\n' "$MONITORING_TOKEN" >.monitoring-token
chown 65534:65534 .monitoring-token
chmod 400 .monitoring-token

escaped_url="${REMOTE_WRITE_URL//\\/\\\\}"
escaped_url="${escaped_url//&/\\&}"
escaped_url="${escaped_url//|/\\|}"
tmp_config="$(mktemp prometheus/agent.yml.tmp.XXXXXX)"
if (( CPU_ONLY )); then
    sed -e '/^  # GPU_SCRAPE_JOB$/d' \
        -e "s|__REMOTE_WRITE_URL__|${escaped_url}|" \
        -e 's|__GPU_ENABLED__|false|' \
        prometheus/agent.yml.template >"$tmp_config"
else
    sed '/^  # GPU_SCRAPE_JOB$/r prometheus/gpu-scrape.yml' \
        prometheus/agent.yml.template |
        sed -e '/^  # GPU_SCRAPE_JOB$/d' \
            -e "s|__REMOTE_WRITE_URL__|${escaped_url}|" \
            -e 's|__GPU_ENABLED__|true|' >"$tmp_config"
fi
chown 65534:65534 "$tmp_config"
chmod 444 "$tmp_config"
mv "$tmp_config" prometheus/agent.yml

info "Pulling and validating the monitoring containers..."
docker compose config >/dev/null
if (( CPU_ONLY )); then
    docker compose pull
else
    docker compose --profile gpu pull
fi
docker compose run --rm --no-deps --entrypoint /bin/promtool prometheus-agent \
    check config /etc/prometheus/agent.yml >/dev/null

if (( CPU_ONLY )); then
    docker compose --profile gpu stop dcgm-exporter >/dev/null 2>&1 || true
    docker compose --profile gpu rm -f dcgm-exporter >/dev/null 2>&1 || true
    info "Starting host and container monitoring..."
    docker compose up -d
else
    info "Starting host, container, and GPU monitoring..."
    docker compose --profile gpu up -d
fi

echo
docker compose --profile gpu ps
echo
ok "'$SERVER_NAME' is sending metrics to the central server."
echo "Mode: $( (( CPU_ONLY )) && echo CPU-only || echo GPU )"
echo "Verify locally with: ./verify-node.sh"
