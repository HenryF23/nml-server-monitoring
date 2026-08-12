#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

agent_port=9095
api="http://127.0.0.1:${agent_port}/api/v1/targets?state=active"

echo "=== Docker services ==="
docker compose --profile gpu ps

echo
echo "=== Prometheus agent scrape targets ==="
if ! command -v curl >/dev/null 2>&1; then
    echo "curl is not installed; open http://127.0.0.1:${agent_port}/targets instead."
    exit 1
fi

if ! payload="$(curl -fsS --max-time 5 "$api")"; then
    echo "[FAIL] Prometheus agent is not reachable on localhost:${agent_port}."
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
targets = json.load(sys.stdin).get("data", {}).get("activeTargets", [])
failed = False
for target in targets:
    labels = target.get("labels", {})
    health = target.get("health", "unknown")
    error = target.get("lastError", "")
    print("[{:<7}] {:<20} {}".format(
        health.upper(), labels.get("job", "?"), target.get("scrapeUrl", "?")
    ))
    if error:
        print(f"          {error}")
    failed = failed or health != "up"
raise SystemExit(1 if failed else 0)
' <<<"$payload"
else
    echo "$payload"
    echo
    echo "[WARN] Install python3 for a readable target summary."
fi
