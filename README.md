# Multi-server GPU monitoring

Dockerized monitoring for servers connected to one Tailscale network. Adding a
server does not require editing the central Prometheus configuration or
restarting it.

Each monitored server runs Node Exporter, cAdvisor, NVIDIA DCGM Exporter, and a
Prometheus Agent. The agent sends metrics over Tailscale to central Prometheus;
Grafana displays them automatically.

```text
monitored server                         central server
Node Exporter ─┐                        Prometheus ── Grafana
cAdvisor ──────┼─ Prometheus Agent ───► 100.x.y.z
DCGM Exporter ─┘       Tailscale
```

The stacks use Docker host networking, so Docker Compose creates no bridge
networks and allocates no private subnets. Central services bind only to the
central Tailscale IP. Node collectors bind only to host loopback.

## Requirements

Every server needs:

- Linux with Docker Engine and Docker Compose v2
- Tailscale, connected to the same tailnet (`tailscale ip -4` must work)
- access through Tailscale to TCP `9090` on the central server

GPU monitoring is the default. GPU servers also need a working NVIDIA driver
and NVIDIA Container Toolkit configured for Docker.

## 1. Start the central server

```bash
cd central
./setup-central.sh
```

The script detects the central server's Tailscale IPv4 address, starts
Prometheus and Grafana on that interface, and prints the exact node setup
command. It generates the Grafana administrator password in `central/.env`.

## 2. Add a monitored server

Copy `node/` to the server and use the central Tailscale IP printed above:

```bash
cd node
sudo ./setup-node.sh --central-ip 100.x.y.z
```

The short hostname is used as the Grafana server label. Override it when
needed:

```bash
sudo ./setup-node.sh --central-ip 100.x.y.z --name gpu-server-01
```

The central IP is saved in `node/.env`, so later GPU-node updates need only:

```bash
sudo ./setup-node.sh
```

New servers normally appear in Grafana within 30 seconds.

### Monitor the central server too

Yes—the two stacks can run on the same host. After central setup, run node
setup with that same host's Tailscale IP:

```bash
cd node
sudo ./setup-node.sh --central-ip 100.x.y.z
```

Their ports do not overlap.

### CPU-only exception

Setup stops with a clear error if an NVIDIA GPU, driver, or container runtime
is unavailable. Only for an intentionally CPU-only server, use:

```bash
sudo ./setup-node.sh --central-ip 100.x.y.z --cpu-only
```

Continue passing `--cpu-only` on later updates.

## Verify

On a monitored server:

```bash
cd node
./verify-node.sh
```

A GPU server should report four `UP` targets. A CPU-only server should report
three.

On the central server:

```bash
cd central
./status.sh
```

Open Grafana at `http://<central-tailscale-ip>:3000`, then select
**Infrastructure → Multi-Server Overview**.

## Network and security

No Caddy proxy or application token is used. Tailscale supplies encrypted,
authenticated transport. Configure Tailscale access controls so monitored
servers can reach central TCP `9090`, and only administrators can reach TCP
`3000`.

| Listener | Binding | Purpose |
|---|---|---|
| `9090/tcp` | central Tailscale IP | Prometheus API and remote write |
| `3000/tcp` | central Tailscale IP | Grafana |
| `9095/tcp` | node `127.0.0.1` | Prometheus Agent status |
| `9100/tcp` | node `127.0.0.1` | Node Exporter |
| `18080/tcp` | node `127.0.0.1` | cAdvisor |
| `9400/tcp` | node `127.0.0.1` | DCGM Exporter |

Because this project creates no Docker networks, it does not consume an
address from Docker's `default-address-pools` and cannot trigger the Compose
subnet exhaustion seen with a single `/24` pool. Other Docker research projects
can still create bridge networks and must follow your site's address-pool rule.

Host networking also means the listed host ports must be free. Existing Nginx
is unaffected unless it already listens on one of those exact address/port
combinations.

## Common commands

```bash
# Update central containers
cd central && docker compose pull && docker compose up -d --remove-orphans

# Update a GPU node
cd node && sudo ./setup-node.sh

# Update a CPU-only node
cd node && sudo ./setup-node.sh --cpu-only

# Stop a node stack
cd node && sudo docker compose --profile gpu down
```

Prometheus retention defaults to 30 days. Image versions, retention, and the
Grafana port can be changed in the generated `.env` files.

## Remove old host installations

The Docker setup does not need host-installed Prometheus, exporters, or
Grafana. Cleanup scripts are included for Debian and Ubuntu:

```bash
# Preview only
./scripts/cleanup-monitoring.sh --dry-run
./scripts/cleanup-grafana.sh --dry-run

# Remove after reviewing the preview
sudo ./scripts/cleanup-monitoring.sh
sudo ./scripts/cleanup-grafana.sh
```

Without `--yes`, each destructive run requires typing `REMOVE`. The scripts do
not remove Docker resources, NVIDIA drivers, CUDA, or NVIDIA Container Toolkit.
