# Multi-server GPU monitoring

Dockerized monitoring for GPU servers, with Tailscale as the preferred private
transport and LAN IPv4 as an explicit fallback. Adding a server does not
require editing or restarting central Prometheus.

Each monitored server runs Node Exporter, cAdvisor, NVIDIA DCGM Exporter, and a
Prometheus Agent. The agent sends metrics to central Prometheus; Grafana
displays them automatically.

```text
monitored server                         central server
Node Exporter ─┐                        Prometheus ── Grafana
cAdvisor ──────┼─ Prometheus Agent ───► central-host:9090
DCGM Exporter ─┘       Tailscale preferred
```

The stacks use Docker host networking, so Docker Compose creates no bridge
networks and allocates no private subnets. Central services prefer the host's
Tailscale interface. Node collectors bind only to host loopback.

## Requirements

Every server needs:

- Linux with Docker Engine and Docker Compose v2
- IPv4 connectivity from each monitored server to central TCP `9090`
- a resolvable central hostname or a reachable central IPv4 address

Install Tailscale on the central and monitored servers for the default setup.
Without Tailscale, central falls back to all host IPv4 interfaces and nodes use
system DNS or an explicit LAN address.

GPU monitoring is the default. GPU servers also need a working NVIDIA driver
and NVIDIA Container Toolkit with the `nvidia` runtime registered in Docker.
On Debian or Ubuntu, install and configure it with:

```bash
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

The NVIDIA package repository must already be configured. If the `nvidia`
runtime is missing, `setup-node.sh` runs these steps automatically; restarting
Docker can briefly interrupt other containers on that server.

## 1. Start the central server

```bash
cd central
./setup-central.sh
```

The script detects the central server's Tailscale IPv4 address and binds
Prometheus and Grafana only to that interface. If Tailscale is unavailable, it
warns and falls back to all IPv4 interfaces. It also generates the Grafana
administrator password in `central/.env`.

To select a LAN or other host interface explicitly:

```bash
./setup-central.sh --bind-address 142.58.10.57
```

The explicit address is saved for later runs. Return to automatic
Tailscale-preferred selection with `./setup-central.sh --auto-bind`. When you
select a specific LAN interface, use that same address with
`setup-node.sh --central-ip`; the central script prints the exact command.

To make Prometheus and Grafana listen on every host IPv4 interface (for example,
both LAN and Tailscale), use:

```bash
./setup-central.sh --bind-address 0.0.0.0
```

This saves `CENTRAL_BIND_ADDRESS=0.0.0.0`. It controls where the services
**listen**; it does not choose the URL Grafana puts in generated links. Because
TCP `9090` and `3000` are then reachable on every permitted interface, restrict
them with your host/network firewall.

For Grafana-generated share/external URLs, set the browser-facing root URL in
`central/.env` to an address your viewers can actually reach:

```bash
GRAFANA_ROOT_URL=http://142.58.10.57:3000
```

and pass it to Grafana in `central/compose.yml` under `grafana.environment`:

```yaml
GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL:-}
```

`GRAFANA_ROOT_URL` only controls Grafana's advertised/generated URL; it does not
change listener binding or network reachability. Recreate Grafana after changing
it with `docker compose up -d --force-recreate grafana`.

## 2. Add a monitored server

Copy `node/` to the server and use the central server's machine name:

```bash
cd node
sudo ./setup-node.sh --central-host cs-nmg-lam01s
```

When Tailscale is available, the script first asks Tailscale for that machine's
IPv4 address. It falls back to system DNS only when Tailscale does not know the
name. The hostname is saved and resolved again on later runs.

Use `--central-ip` when you intentionally want a specific address, including
LAN transport:

```bash
sudo ./setup-node.sh --central-ip 142.58.10.57
```

The monitored server name is resolved automatically with `hostname -s`. Use
`--name gpu-server-01` only when you want to override it.

If the central server also monitors itself, resolve its hostname and server
label automatically:

```bash
cd node
sudo ./setup-node.sh \
  --central-host "$(hostname -s)"
```

To override the Grafana server label explicitly:

```bash
sudo ./setup-node.sh --central-host cs-nmg-lam01s --name gpu-server-01
```

The central host and resolved IP are saved in `node/.env`, so later GPU-node
updates need only:

```bash
sudo ./setup-node.sh
```

New servers normally appear in Grafana within 30 seconds.

The central and node stacks can run on the same host; their ports do not
overlap.

Node setup also reads Docker's actual data directory from `docker info` and
mounts that directory read-only into cAdvisor. Custom Docker roots therefore
need no manual Compose edits, and missing paths are never created silently.
On GPU nodes it also starts a temporary DCGM Exporter container and runs
`nvidia-smi -L`, so setup fails before deployment if Docker cannot access the
GPU. All nodes use the same NVIDIA runtime configuration; no per-server
Compose changes or CDI/legacy detection are needed.

### CPU-only exception

Setup stops with a clear error if an NVIDIA GPU, driver, or container runtime
is unavailable. Only for an intentionally CPU-only server, use:

```bash
sudo ./setup-node.sh --central-host cs-nmg-lam01s --cpu-only
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

Node Exporter reads the host root filesystem through a read-only bind mount.
If you attach or mount a new filesystem after the node stack has started,
refresh its filesystem metrics with:

```bash
sudo docker compose restart node-exporter
```

On the central server:

```bash
cd central
./status.sh
```

Open Grafana at `http://<central-host>:3000`, then select
**NML → GPU Server Availability**. Both dashboards and their navigation links
use the latest 24 hours.

The first screen is designed for choosing a server:

- **Available** means every GPU is free and host CPU usage is below 25%.
- **Has Capacity** means some GPUs are free and host CPU usage is below 25%.
- **CPU Busy** means GPUs are free but host CPU usage is at least 25%.
- **In Use** means no GPU currently meets the free threshold.
- **CPU Only** identifies a node intentionally installed with `--cpu-only`.
- **Metrics Missing** means node monitoring is online but GPU status is absent.
- **Offline** means a server was seen within 24 hours but has no current data.

A GPU is considered free when its five-minute average compute and VRAM usage
are both below 10%. The **Free** column shows the exact usable count, so a
four-GPU server with two occupied GPUs and low host CPU is shown as
**Has Capacity · 2 free**.

The table is ordered for scheduling: Available, Has Capacity, CPU Busy, In Use,
CPU Only, Metrics Missing, then Offline. Its columns are **Server**, **Status**,
**GPU Model**, **GPUs**, **Free**, **GPU Util**, **VRAM**, **CPU**, **Memory**,
**GPU Temp**, and **CPU Temp**. Missing values display as `N/A`; CPU temperature
is unavailable when the host exposes no supported hwmon sensor. Disk usage
remains in **Server Details**, and Tailscale IPs are intentionally omitted. The
GPU model summary assumes the GPUs within one server share a model.

Click a server name in the table to open **Server Details** for the latest 24
hours. That view shows per-GPU inventory, compute, VRAM,
temperature and power history, host CPU/RAM/disk history, and the busiest
application containers. Its **Server** selector switches directly between
machines.

## Network and security

No Caddy proxy or application token is used. The default Tailscale binding
limits both central listeners to the private tailnet. Grafana requires its
generated administrator password; Prometheus remote write does not have
application-level authentication. Use Tailscale access controls so monitored
servers can reach TCP `9090` and only administrators can reach TCP `3000`.

If Tailscale is unavailable or you explicitly bind to `0.0.0.0`, restrict both
ports with the host firewall and use the setup only on a trusted private LAN.

| Listener | Binding | Purpose |
|---|---|---|
| `9090/tcp` | central `CENTRAL_BIND_ADDRESS` | Prometheus API and remote write |
| `3000/tcp` | central `CENTRAL_BIND_ADDRESS` | Grafana |
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
cd central && ./setup-central.sh

# Update a GPU node
cd node && sudo ./setup-node.sh

# Update a CPU-only node
cd node && sudo ./setup-node.sh --cpu-only

# Stop a node stack
cd node && sudo docker compose --profile gpu down
```

Prometheus retention defaults to 30 days. Image versions, retention, and the
Grafana port can be changed in the generated `.env` files. DCGM Exporter is
pinned to `4.6.0-4.8.3-distroless`; setup replaces older saved `latest` or
previously generated unsuffixed values with that pin while preserving other
explicit custom version tags.

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
