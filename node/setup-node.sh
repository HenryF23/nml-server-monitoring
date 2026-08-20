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
  sudo ./setup-node.sh --central-host HOSTNAME [--name NAME] [--cpu-only] [--same-host]
  sudo ./setup-node.sh --central-ip IPV4 [--name NAME] [--cpu-only] [--same-host]

The central host or IP is saved after the first run. --central-host prefers
Tailscale and falls back to system DNS. Use --central-ip to select an address
explicitly. Use --same-host when this node also runs the central stack; use
--bridge to return to the default remote-node networking mode. GPU monitoring
is the default; use --cpu-only only without a GPU.
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

    RESOLVED_CENTRAL_IP=""
    RESOLUTION_METHOD=""

    if command -v tailscale >/dev/null 2>&1; then
        candidate="$(tailscale ip -4 "$host" 2>/dev/null | head -n1 || true)"
        if is_ipv4 "$candidate"; then
            RESOLVED_CENTRAL_IP="$candidate"
            RESOLUTION_METHOD="Tailscale"
            return 0
        fi
    fi

    command -v getent >/dev/null 2>&1 || \
        die "Central host '$host' is unknown to Tailscale and getent is unavailable."

    while read -r candidate _; do
        if is_ipv4 "$candidate"; then
            RESOLVED_CENTRAL_IP="$candidate"
            RESOLUTION_METHOD="system DNS"
            return 0
        fi
    done < <({ getent ahostsv4 "$host" || getent hosts "$host"; } 2>/dev/null || true)

    die "Central host '$host' is unknown to Tailscale and did not resolve through system DNS."
}

has_nvidia_runtime() {
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

ensure_nvidia_runtime() {
    has_nvidia_runtime && return 0

    warn "The NVIDIA runtime is not registered with Docker."
    command -v apt-get >/dev/null 2>&1 || \
        die "Install NVIDIA Container Toolkit, configure the Docker runtime, and rerun setup."

    info "Refreshing APT package indexes..."
    apt-get update || \
        die "Could not refresh APT package indexes. Check the configured repositories and rerun setup."
    info "Installing NVIDIA Container Toolkit..."
    apt-get install -y nvidia-container-toolkit || \
        die "Could not install nvidia-container-toolkit. Configure NVIDIA's package repository and rerun setup."
    command -v nvidia-ctk >/dev/null 2>&1 || \
        die "nvidia-ctk is unavailable after installing NVIDIA Container Toolkit."

    info "Configuring the NVIDIA runtime for Docker..."
    nvidia-ctk runtime configure --runtime=docker || \
        die "Could not configure the NVIDIA runtime for Docker."
    command -v systemctl >/dev/null 2>&1 || \
        die "Restart Docker, then rerun setup."

    warn "Restarting Docker to activate the NVIDIA runtime."
    systemctl restart docker || die "Could not restart Docker."
    docker info >/dev/null 2>&1 || die "Docker did not become available after restart."
    has_nvidia_runtime || die "Docker restarted, but the NVIDIA runtime is still unavailable."
    ok "NVIDIA Container Toolkit is configured for Docker."
}

SERVER_NAME=""
CENTRAL_IP=""
CENTRAL_HOST=""
RESOLVED_CENTRAL_IP=""
RESOLUTION_METHOD=""
CPU_ONLY=0
SAME_HOST_MODE=""
DCGM_EXPORTER_PINNED_TAG="4.6.0-4.8.3-distroless"

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
        --same-host) SAME_HOST_MODE=true; shift ;;
        --bridge) SAME_HOST_MODE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -z "$CENTRAL_IP" || -z "$CENTRAL_HOST" ]] || \
    die "Use either --central-host or --central-ip, not both."

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."
command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is required."
docker info >/dev/null 2>&1 || die "Cannot connect to the Docker daemon."

if (( ! CPU_ONLY )); then
    gpu_error="If this is intentionally a CPU-only server, rerun with --cpu-only."
    command -v nvidia-smi >/dev/null 2>&1 || \
        die "No NVIDIA driver or GPU was found. $gpu_error"
    nvidia-smi >/dev/null 2>&1 || \
        die "The NVIDIA GPU is installed but cannot be accessed. $gpu_error"
    ensure_nvidia_runtime
else
    info "CPU-only mode selected; GPU metrics will be disabled."
fi

DOCKER_ROOT_DIR="$(docker info --format '{{.DockerRootDir}}')"
[[ "$DOCKER_ROOT_DIR" == /* && "$DOCKER_ROOT_DIR" != "/" ]] || \
    die "Docker returned an invalid data root: '$DOCKER_ROOT_DIR'."
[[ -d "$DOCKER_ROOT_DIR" ]] || \
    die "Docker data root does not exist: '$DOCKER_ROOT_DIR'."

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
SAME_HOST_MODE="${SAME_HOST_MODE:-$(read_env SAME_HOST)}"
SAME_HOST_MODE="${SAME_HOST_MODE:-false}"
[[ "$SAME_HOST_MODE" == "true" || "$SAME_HOST_MODE" == "false" ]] || \
    die "Invalid SAME_HOST '$SAME_HOST_MODE'. Use true or false."

if [[ -z "$CENTRAL_HOST" && -z "$CENTRAL_IP" ]]; then
    CENTRAL_HOST="$(read_env CENTRAL_HOST)"
    if [[ -z "$CENTRAL_HOST" ]]; then
        CENTRAL_IP="$(read_env CENTRAL_IP)"
    fi
fi

if [[ -n "$CENTRAL_HOST" ]]; then
    resolve_central_host "$CENTRAL_HOST"
    CENTRAL_IP="$RESOLVED_CENTRAL_IP"
    info "Resolved central host '$CENTRAL_HOST' to $CENTRAL_IP via $RESOLUTION_METHOD."
fi

[[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    die "Invalid server name '$SERVER_NAME'."
is_ipv4 "$CENTRAL_IP" || \
    die "Provide --central-host HOSTNAME or --central-ip with a valid IPv4 address."

[[ -f .env ]] || cp .env.example .env
set_env SERVER_NAME "$SERVER_NAME"
set_env CENTRAL_HOST "$CENTRAL_HOST"
set_env CENTRAL_IP "$CENTRAL_IP"
set_env DOCKER_ROOT_DIR "$DOCKER_ROOT_DIR"
set_env SAME_HOST "$SAME_HOST_MODE"
if [[ "$SAME_HOST_MODE" == "true" ]]; then
    set_env COMPOSE_FILE "compose.yml:compose.same-host.yml"
else
    set_env COMPOSE_FILE "compose.yml"
fi

dcgm_exporter_tag="$(read_env DCGM_EXPORTER_TAG)"
if [[ -z "$dcgm_exporter_tag" || "$dcgm_exporter_tag" == "latest" || \
      "$dcgm_exporter_tag" == "${DCGM_EXPORTER_PINNED_TAG%-distroless}" ]]; then
    if [[ -n "$dcgm_exporter_tag" ]]; then
        info "Replacing DCGM Exporter tag '$dcgm_exporter_tag' with $DCGM_EXPORTER_PINNED_TAG."
    fi
    set_env DCGM_EXPORTER_TAG "$DCGM_EXPORTER_PINNED_TAG"
fi
chmod 600 .env

mkdir -p data/prometheus-agent
chown 65534:65534 data/prometheus-agent

tmp_config="$(mktemp prometheus/agent.yml.tmp.XXXXXX)"
cleanup_tmp_config() {
    [[ -z "$tmp_config" ]] || rm -f -- "$tmp_config"
}
trap cleanup_tmp_config EXIT
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

if [[ "$SAME_HOST_MODE" == "true" ]]; then
    info "Central and node share this machine; using host networking for the local node."
else
    info "Using Docker's built-in bridge with one shared network namespace; no Compose network will be created."
fi
info "Using Docker data root $DOCKER_ROOT_DIR for cAdvisor."
info "Pulling and validating the monitoring containers..."
docker compose config >/dev/null
if (( CPU_ONLY )); then
    docker compose pull
else
    docker compose --profile gpu pull
fi
prometheus_version="$(read_env PROMETHEUS_VERSION)"
prometheus_version="${prometheus_version:-v3.13.2}"
docker run --rm --network none \
    --env "SERVER_NAME=${SERVER_NAME}" \
    --entrypoint /bin/promtool \
    --mount "type=bind,src=${PWD}/${tmp_config},dst=/etc/prometheus/agent.yml,readonly" \
    "prom/prometheus:${prometheus_version}" \
    check config /etc/prometheus/agent.yml >/dev/null

if (( ! CPU_ONLY )); then
    info "Checking NVIDIA GPU access from Docker..."
    dcgm_exporter_tag="$(read_env DCGM_EXPORTER_TAG)"
    if ! docker run --rm --network none --runtime nvidia \
        --env NVIDIA_VISIBLE_DEVICES=all \
        --entrypoint nvidia-smi \
        "nvcr.io/nvidia/k8s/dcgm-exporter:${dcgm_exporter_tag}" -L >/dev/null; then
        die "Docker cannot access the NVIDIA GPU through the NVIDIA runtime. Check the NVIDIA driver and Container Toolkit configuration; use --cpu-only only when this server intentionally has no GPU."
    fi
    ok "NVIDIA GPU access from Docker is working."
fi

if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "http://${CENTRAL_IP}:9090/-/ready" >/dev/null; then
        ok "Central Prometheus is reachable at ${CENTRAL_IP}:9090."
    else
        warn "Central Prometheus is not reachable at ${CENTRAL_IP}:9090."
        warn "Check setup-central.sh, routing, and firewall access to TCP 9090."
    fi
fi

mv "$tmp_config" prometheus/agent.yml
tmp_config=""

if (( CPU_ONLY )); then
    docker compose --profile gpu stop dcgm-exporter >/dev/null 2>&1 || true
    docker compose --profile gpu rm -f dcgm-exporter >/dev/null 2>&1 || true
    info "Starting host and container monitoring..."
    docker compose up -d --remove-orphans --force-recreate
else
    info "Starting host, container, and GPU monitoring..."
    docker compose --profile gpu up -d --remove-orphans --force-recreate
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
echo "Network : $( [[ "$SAME_HOST_MODE" == "true" ]] && echo same-host || echo bridge )"
echo "Verify  : sudo ./verify-node.sh"
