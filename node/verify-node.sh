#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

agent_port=9095
api="http://127.0.0.1:${agent_port}/api/v1/targets?state=active"

read_env() {
    local key="$1"
    [[ -f .env ]] || return 0
    grep -m1 -E "^${key}=" .env 2>/dev/null | cut -d= -f2- || true
}

command -v curl >/dev/null 2>&1 || {
    echo "[FAIL] curl is required."
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "[FAIL] python3 is required for strict target validation."
    exit 1
}
[[ -f prometheus/agent.yml ]] || {
    echo "[FAIL] prometheus/agent.yml is missing; run setup-node.sh first."
    exit 1
}

if grep -q '^[[:space:]]*- job_name: dcgm-exporter$' prometheus/agent.yml; then
    expected_jobs="prometheus-agent,node-exporter,cadvisor,dcgm-exporter"
else
    expected_jobs="prometheus-agent,node-exporter,cadvisor"
fi
failed=0

echo "=== Docker services ==="
docker compose --profile gpu ps

echo
echo "=== Prometheus agent scrape targets ==="
if ! payload="$(curl -fsS --max-time 5 "$api")"; then
    echo "[FAIL] Prometheus agent is not reachable on localhost:${agent_port}."
    exit 1
fi

if ! python3 -c '
import json, sys
targets = json.load(sys.stdin).get("data", {}).get("activeTargets", [])
expected = set(sys.argv[1].split(","))
actual = []
failed = False
for target in targets:
    labels = target.get("labels", {})
    job = labels.get("job", "?")
    actual.append(job)
    health = target.get("health", "unknown")
    error = target.get("lastError", "")
    print("[{:<7}] {:<20} {}".format(
        health.upper(), job, target.get("scrapeUrl", "?")
    ))
    if error:
        print(f"          {error}")
    failed = failed or health != "up"
if len(actual) != len(expected) or set(actual) != expected:
    missing = sorted(expected - set(actual))
    unexpected = sorted(set(actual) - expected)
    print(f"[FAIL] Expected exactly {len(expected)} targets; received {len(actual)}.", file=sys.stderr)
    if missing:
        print("       Missing jobs: {}".format(", ".join(missing)), file=sys.stderr)
    if unexpected:
        print("       Unexpected jobs: {}".format(", ".join(unexpected)), file=sys.stderr)
    if len(actual) != len(set(actual)):
        print("       Duplicate job targets were returned.", file=sys.stderr)
    failed = True
raise SystemExit(1 if failed else 0)
' "$expected_jobs" <<<"$payload"; then
    failed=1
fi

echo
echo "=== Central Prometheus ==="
central_ip="$(read_env CENTRAL_IP)"
if [[ -z "$central_ip" ]]; then
    echo "[FAIL] CENTRAL_IP is missing from node/.env; rerun setup-node.sh."
    failed=1
elif curl -fsS --max-time 5 "http://${central_ip}:9090/-/ready" >/dev/null; then
    echo "[UP     ] http://${central_ip}:9090/-/ready"
else
    echo "[FAIL] Central Prometheus is not reachable at ${central_ip}:9090."
    failed=1
fi

exit "$failed"
