#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

read_env() {
    local key="$1"
    grep -m1 -E "^${key}=" .env 2>/dev/null | cut -d= -f2- || true
}

tailscale_ip="$(read_env TAILSCALE_IP)"
if [[ -z "$tailscale_ip" ]] && command -v tailscale >/dev/null 2>&1; then
    tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1)"
fi
[[ -n "$tailscale_ip" ]] || {
    echo "TAILSCALE_IP is missing. Run ./setup-central.sh first."
    exit 1
}

api="http://${tailscale_ip}:9090/api/v1/query"
query='up{job=~"prometheus-agent|node-exporter|cadvisor|dcgm-exporter"}'

echo "=== Docker services ==="
docker compose ps

echo
echo "=== Metrics currently arriving from monitored servers ==="
command -v curl >/dev/null 2>&1 || {
    echo "curl is required to query the Prometheus API."
    exit 1
}

if ! payload="$(curl -fsS --get --data-urlencode "query=$query" "$api")"; then
    echo "Prometheus is not reachable at ${tailscale_ip}:9090."
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
results = json.load(sys.stdin).get("data", {}).get("result", [])
if not results:
    print("No node metrics have arrived yet.")
    print("Run node/setup-node.sh on a monitored server, then wait 15-30 seconds.")
    raise SystemExit

rows = []
for result in results:
    metric = result.get("metric", {})
    mode = "GPU" if metric.get("gpu") == "true" else "CPU"
    rows.append((metric.get("server", "?"), mode, metric.get("job", "?"), result.get("value", [0, "?"])[1]))

print("{:<28} {:<5} {:<20} STATUS".format("SERVER", "MODE", "JOB"))
print("-" * 64)
for server, mode, job, value in sorted(rows):
    status = "UP" if value == "1" else "DOWN"
    print("{:<28} {:<5} {:<20} {}".format(server, mode, job, status))
' <<<"$payload"
else
    echo "$payload"
    echo
    echo "Install python3 for a readable status table."
fi
