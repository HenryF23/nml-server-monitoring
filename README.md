# Multi-server monitoring with Docker

A central Docker stack stores and displays metrics from any number of
servers. GPU monitoring is enabled by default. Each GPU server runs four
containers:

- Node Exporter for host metrics
- cAdvisor for Docker container metrics
- NVIDIA DCGM Exporter for GPU metrics
- Prometheus Agent to send everything to the central server

Adding a server requires one command on that server. There is no central target
list to edit and no Prometheus restart.

```text
GPU server                                      central server
┌──────────────────────────────┐                ┌──────────────────────┐
│ Node Exporter ─┐             │                │ authenticated        │
│ cAdvisor ──────┼─ Prometheus Agent ─────────► │ gateway              │
│ DCGM Exporter ─┘             │  remote write  │   └─ Prometheus      │
└──────────────────────────────┘                │       └─ Grafana     │
                                                └──────────────────────┘
```

## Requirements

All servers need Docker Engine and Docker Compose v2.

GPU servers must also have:

- a working NVIDIA driver (`nvidia-smi` must succeed);
- NVIDIA Container Toolkit configured for Docker;
- network access to TCP `9091` on the central server.

## 1. Start the central server

```bash
cd central
./setup-central.sh
```

This starts Prometheus, Grafana, and the authenticated metrics gateway. It also
generates the Grafana password and monitoring token in `central/.env`.

The final output contains the command to run on every server. Replace the
hostname with the central server's private IP or VPN hostname when necessary.

## 2. Add a server

Copy `node/` to the server and run the command printed by central setup:

```bash
cd node
sudo ./setup-node.sh \
  --central-url http://10.0.0.10:9091/api/v1/write \
  --token TOKEN_FROM_CENTRAL
```

The short hostname becomes the server name in Grafana. It must be unique. To
set it explicitly:

```bash
sudo ./setup-node.sh \
  --central-url http://10.0.0.10:9091/api/v1/write \
  --token TOKEN_FROM_CENTRAL \
  --name gpu-server-01
```

The URL and token are saved locally. Future updates only require:

```bash
sudo ./setup-node.sh
```

New servers appear automatically in Grafana within about 30 seconds.

### CPU-only exception

Setup expects a working GPU by default. It stops with a clear error when the
NVIDIA driver, GPU access, or NVIDIA Container Toolkit is unavailable. If the
server intentionally has no GPU, opt out explicitly:

```bash
sudo ./setup-node.sh \
  --central-url http://10.0.0.10:9091/api/v1/write \
  --token TOKEN_FROM_CENTRAL \
  --cpu-only
```

On later CPU-only updates, continue passing the flag:

```bash
sudo ./setup-node.sh --cpu-only
```

## Verify

On a monitored server:

```bash
cd node
./verify-node.sh
```

GPU servers should report four `UP` targets. CPU-only servers should report
three; DCGM Exporter is not started or scraped.

On the central server:

```bash
cd central
./status.sh
```

Grafana is available at `http://<central-server>:3000`. Open
**Infrastructure → Multi-Server Overview** and use the **Server** selector.

## Network exposure

The central server exposes:

- `3000/tcp`: Grafana
- `9091/tcp`: authenticated metric ingestion
- `9090/tcp`: Prometheus, bound to localhost by default

Monitored servers expose no exporter ports. Their Prometheus Agent status page
is available only at `http://127.0.0.1:9095/targets`.

The ingestion endpoint uses a bearer token but plain HTTP by default. Keep port
`9091` on a trusted LAN or VPN. Use an HTTPS reverse proxy when metrics cross
an untrusted network.

Generated secrets and node configuration are excluded from Git:

- `central/.env`
- `node/.env`
- `node/.monitoring-token`
- `node/prometheus/agent.yml`

## Common commands

```bash
# Update central containers
cd central && docker compose pull && docker compose up -d

# Update a monitored server
cd node && sudo ./setup-node.sh

# Update a CPU-only server
cd node && sudo ./setup-node.sh --cpu-only

# Stop monitoring a server
cd node && sudo docker compose down
```

Container versions and ports can be changed in the generated `.env` files.
Prometheus retention defaults to 30 days.

## Remove old host installations

The Docker setup does not need host-installed Prometheus, exporters, or
Grafana. Two cleanup scripts are included for Debian and Ubuntu:

```bash
# Preview only; no changes
./scripts/cleanup-monitoring.sh --dry-run
./scripts/cleanup-grafana.sh --dry-run

# Perform the cleanup after reviewing the preview
sudo ./scripts/cleanup-monitoring.sh
sudo ./scripts/cleanup-grafana.sh
```

Root is not required for a preview, although `sudo --dry-run` provides complete
process visibility. Without `--yes`, each destructive run requires typing
`REMOVE`. These scripts
purge the matching host packages and remove their host configuration, data,
logs, and manual-install files. They never remove Docker containers, images,
networks, volumes, NVIDIA drivers, CUDA, or NVIDIA Container Toolkit.
