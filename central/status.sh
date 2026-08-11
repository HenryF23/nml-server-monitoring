#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

prometheus_port="$(grep -m1 '^PROMETHEUS_PORT=' .env 2>/dev/null | cut -d= -f2- || true)"
prometheus_port="${prometheus_port:-9090}"
api="http://127.0.0.1:${prometheus_port}/api/v1/query"
query='up{job=~"prometheus-agent|node-exporter|cadvisor|dcgm-exporter"}'

echo "=== Docker services ==="
docker compose ps

echo
echo "=== Metrics currently arriving from monitored servers ==="
command -v curl >/dev/null 2>&1 || {
    echo "curl is required to query the local Prometheus API."
    exit 1
}

if ! payload="$(curl -fsS --get --data-urlencode "query=$query" "$api")"; then
    echo "Prometheus API is not reachable on localhost:${prometheus_port}."
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
