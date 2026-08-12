# Multi-server GPU monitoring

Dockerized monitoring for GPU and CPU-only servers. Tailscale is the preferred
private transport, with LAN IPv4 available as an explicit fallback. Nodes send
metrics to central Prometheus by remote write, so adding a server does not
require editing or restarting the central stack.

```text
monitored server                         central server
Node Exporter ─┐                        Prometheus ── Grafana
cAdvisor ──────┼─ Prometheus Agent ───► central-host:9090
DCGM Exporter* ─┘

* GPU nodes only
```

## Requirements

The central and monitored servers need Linux, Docker Engine, and the
`docker compose` plugin. Each monitored server must be able to reach central
TCP `9090` using either a resolvable hostname or an IPv4 address.

Tailscale should be installed on all servers for the default setup. Without a
local Tailscale IPv4 address, central setup fails closed until you explicitly
select a LAN address or `0.0.0.0`. Nodes can use Tailscale name resolution,
system DNS, or a fixed IPv4 address.

GPU nodes also need a working NVIDIA driver and the NVIDIA Container Toolkit
package repository. If Docker's `nvidia` runtime is missing, `setup-node.sh`
installs the toolkit through APT, configures the runtime, and restarts Docker.
That restart can briefly interrupt other containers on the node.

## 1. Start the central server

```bash
cd central
./setup-central.sh
```

Automatic mode binds Prometheus and Grafana to the central server's Tailscale
IPv4 address. Setup validates the configuration, starts both services, and
creates `central/.env` with a generated Grafana administrator password.

Use an explicit host address when automatic Tailscale binding is unsuitable:

```bash
# Bind to one LAN interface
./setup-central.sh --bind-address 142.58.10.57

# Bind to every host IPv4 interface
./setup-central.sh --bind-address 0.0.0.0

# Return to automatic Tailscale binding
./setup-central.sh --auto-bind
```

The selection is saved in `central/.env`. When binding to one LAN address, pass
that address to nodes with `--central-ip`; setup prints the corresponding node
command. Binding to `0.0.0.0` exposes Prometheus and Grafana on every permitted
host interface, so restrict both ports to trusted clients.

Set `GRAFANA_ROOT_URL` in `central/.env` when viewers use a hostname, address,
port, HTTPS proxy, or subpath other than Grafana's default URL:

```dotenv
GRAFANA_ROOT_URL=http://142.58.10.57:3000
```

Then recreate Grafana:

```bash
docker compose up -d --no-deps --force-recreate grafana
```

`GRAFANA_ROOT_URL` controls redirects and generated links only; it does not
change port publication or network reachability.

## 2. Add a monitored server

Copy `node/` to the server, then run:

```bash
cd node
sudo ./setup-node.sh --central-host cs-nmg-lam01s
```

`--central-host` resolves through Tailscale first and system DNS second. The
central hostname, resolved IPv4 address, and server label are saved in
`node/.env`; the default label is `hostname -s`.

Common alternatives are:

```bash
# Use a fixed central address
sudo ./setup-node.sh --central-ip 142.58.10.57

# Override the Grafana server label
sudo ./setup-node.sh --central-host cs-nmg-lam01s --name gpu-server-01

# Intentionally omit GPU monitoring
sudo ./setup-node.sh --central-host cs-nmg-lam01s --cpu-only
```

GPU monitoring is the default and setup fails if the driver, GPU, or NVIDIA
runtime is unavailable. Use `--cpu-only` only for an intentionally CPU-only
server, and continue passing it on future updates.

Setup detects Docker's data directory for cAdvisor, validates the generated
Prometheus Agent configuration, and verifies GPU access from Docker on GPU
nodes. New nodes normally appear in Grafana within 30 seconds. To monitor the
central server itself, run the same node setup there.

## Verify

On a monitored server:

```bash
cd node
sudo ./verify-node.sh
```

Verification requires `curl` and `python3`. It requires exactly four healthy
targets on a GPU node or three on a CPU-only node, and checks that central
Prometheus is reachable.

On the central server:

```bash
cd central
./status.sh
```

## Dashboards

Open `http://<central-host>:3000` (or the configured `GRAFANA_PORT`) and select
**NML → GPU Server Availability**. Dashboards refresh every 15 seconds and
default to the latest three hours.

A GPU is free when both its five-minute average compute utilization and VRAM
allocation are below 10%. Server states are:

| Status | Meaning |
|---|---|
| **Available** | Every GPU is free and host CPU is below 25%. |
| **Has Capacity** | Some, but not all, GPUs are free and host CPU is below 25%. |
| **CPU Busy** | At least one GPU is free but host CPU is at least 25%. |
| **In Use** | No GPU meets the free threshold. |
| **CPU Only** | The node was installed with `--cpu-only`. |
| **Metrics Missing** | Node monitoring is online but GPU status is unavailable. |
| **Offline** | The server was seen within 24 hours but has no current node data. |

The overview is ordered by that scheduling priority. Its **Free** column shows
the usable GPU count. GPU Compute and VRAM history show the maximum across each
server's GPUs at every timestamp; the contributing GPU can change over time.

Click a server name to open **Server Details** for fixed per-GPU traces, GPU
inventory, host CPU/memory/disk history, and the busiest application containers.
Missing values display as `N/A`; CPU temperature is unavailable without a
supported Linux hwmon sensor. The GPU model summary is intended for servers with
a homogeneous GPU model.

**GPU Server Availability · External** mirrors the overview and drill-down
links, but has no server selector and always shows the full fleet. It still
requires Grafana authentication; iframe embedding is not enabled.

## Network and security

Grafana authentication is enabled, while Prometheus remote write has no
application-level authentication. Automatic setup publishes both central ports
only on the Tailscale address. Use Tailscale access controls so nodes can reach
TCP `9090` and only administrators can reach Grafana.

For LAN bindings—and especially `0.0.0.0`—use a trusted private network and
restrict both ports with Docker-compatible or upstream firewall rules. Docker's
published ports can bypass ordinary UFW rules; see Docker's
[packet-filtering and firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

| Listener | Binding | Purpose |
|---|---|---|
| `9090/tcp` | Central `CENTRAL_BIND_ADDRESS` | Prometheus API and remote write |
| `GRAFANA_PORT` (`3000` by default) | Central `CENTRAL_BIND_ADDRESS` | Grafana |
| `9095/tcp` | Node `127.0.0.1` | Prometheus Agent status |
| `9100/tcp` | Node container loopback | Node Exporter |
| `18080/tcp` | Node container loopback | cAdvisor |
| `9400/tcp` | Node container loopback | DCGM Exporter |

Docker releases older than 28.0 can expose loopback-published ports to hosts on
the same layer-2 network; see Docker's
[port-publishing documentation](https://docs.docker.com/engine/network/port-publishing/).

Both stacks use Docker's built-in `bridge` and one shared network namespace per
stack. Compose creates no project networks or additional subnets. This avoids
subnet allocation from Docker's `default-address-pools`, but the built-in bridge
provides weaker isolation from unrelated containers; use trusted Docker hosts.

When central and node stacks share a host, their default ports do not conflict.
If central binds to `0.0.0.0`, do not set `GRAFANA_PORT=9095` because the node
Agent already publishes that port on loopback.

## Operations

```bash
# Update central
cd central && ./setup-central.sh

# Update a GPU node
cd node && sudo ./setup-node.sh

# Update a CPU-only node
cd node && sudo ./setup-node.sh --cpu-only

# Stop a node stack
cd node && sudo docker compose --profile gpu down

# Refresh filesystem metrics after adding or mounting a filesystem
cd node && sudo docker compose restart node-exporter
```

Prometheus retention defaults to 30 days. Image versions, retention, and the
Grafana port are configurable in the generated `.env` files. DCGM Exporter is
pinned to `4.6.0-4.8.3-distroless`; setup migrates legacy generated tags while
preserving explicit custom versions.

Provisioned dashboards are read-only in Grafana. Edit the JSON files under
`central/grafana/dashboards/`; Grafana scans them for changes every 30 seconds.

After upgrading from the former host-networked release, run `setup-central.sh`
and `setup-node.sh` once to recreate the containers while preserving their named
volumes. Continue to pass `--cpu-only` on CPU-only nodes.

## Remove old host installations

The Docker setup does not need host-installed Prometheus, exporters, or
Grafana. Cleanup scripts are provided for Debian and Ubuntu:

```bash
# Preview
./scripts/cleanup-monitoring.sh --dry-run
./scripts/cleanup-grafana.sh --dry-run

# Remove after reviewing the preview
sudo ./scripts/cleanup-monitoring.sh
sudo ./scripts/cleanup-grafana.sh
```

Without `--yes`, a destructive run requires typing `REMOVE`. The scripts leave
Docker resources, NVIDIA drivers, CUDA, and NVIDIA Container Toolkit intact.
