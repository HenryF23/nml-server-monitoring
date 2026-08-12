# Multi-server GPU monitoring

Dockerized monitoring for GPU servers, with Tailscale as the preferred private
transport and LAN IPv4 as an explicit fallback. Adding a server does not
require editing or restarting central Prometheus.

Each monitored server runs Node Exporter, cAdvisor, and a Prometheus Agent. GPU
servers also run NVIDIA DCGM Exporter. The agent sends metrics to central
Prometheus; Grafana displays them automatically.

```text
monitored server                         central server
Node Exporter ─┐                        Prometheus ── Grafana
cAdvisor ──────┼─ Prometheus Agent ───► central-host:9090
DCGM Exporter* ─┘      Tailscale preferred

* GPU nodes only
```

Both stacks use Docker's existing built-in `bridge`, so they do not create
Compose networks or allocate additional private subnets. Grafana shares
Prometheus's network namespace; on each monitored server, the collectors share
the Prometheus Agent's network namespace. Components within each stack
communicate over container loopback. Central services prefer the host's
Tailscale interface.

## Requirements

Every server needs:

- Linux with Docker Engine and the `docker compose` plugin
- IPv4 connectivity from each monitored server to central TCP `9090`
- a resolvable central hostname or a reachable central IPv4 address

Install Tailscale on the central and monitored servers for the default setup.
Without Tailscale, central setup fails closed until you explicitly select a LAN
address or `0.0.0.0`; nodes can use system DNS or an explicit LAN address.

GPU monitoring is the default. GPU servers also need a working NVIDIA driver
and NVIDIA Container Toolkit with the `nvidia` runtime registered in Docker.
On Debian or Ubuntu, install and configure it with:

```bash
sudo apt-get update
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

The script detects the central server's Tailscale IPv4 address and publishes
Prometheus and Grafana only on that host interface. If Tailscale is unavailable,
it stops instead of exposing unauthenticated Prometheus automatically. Select a
LAN address or explicitly select all interfaces as shown below. Setup also
generates the Grafana administrator password in `central/.env`.

To select a LAN or other host interface explicitly:

```bash
./setup-central.sh --bind-address 142.58.10.57
```

The explicit address is saved for later runs. Return to automatic
Tailscale-preferred selection with `./setup-central.sh --auto-bind`. When you
select a specific LAN interface, use that same address with
`setup-node.sh --central-ip`; the central script prints the exact command.

To publish Prometheus and Grafana on every host IPv4 interface (for example,
both LAN and Tailscale), use:

```bash
./setup-central.sh --bind-address 0.0.0.0
```

This saves `CENTRAL_BIND_ADDRESS=0.0.0.0`. It controls the host IP used by
Docker's published ports; Grafana and Prometheus listen on all interfaces only
inside their shared container network namespace. It does not choose the URL
Grafana puts in generated links. Because Prometheus TCP `9090` and Grafana TCP
`GRAFANA_PORT` (`3000` by default) are then reachable on every permitted host
interface, restrict them with
Docker-compatible firewall rules or an upstream network firewall.

For Grafana-generated share/external URLs, set the browser-facing root URL in
`central/.env` to an address your viewers can actually reach:

```bash
GRAFANA_ROOT_URL=http://142.58.10.57:3000
```

`GRAFANA_ROOT_URL` only controls Grafana's advertised/generated URL; it does not
change port publication or network reachability. It is optional, but Grafana's
default root URL is `http://localhost:3000`; set it when clients use another
hostname, address, port, HTTPS proxy, or subpath. Recreate Grafana after changing
it with `docker compose up -d --no-deps --force-recreate grafana`.

After upgrading from the earlier host-networked central stack, run
`./setup-central.sh` once instead of starting Compose directly. The script
removes the legacy datasource override and recreates both containers while
preserving their named volumes.

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

Run that command once on existing GPU nodes after upgrading from the earlier
host-networked stack. For existing CPU-only nodes, rerun
`sudo ./setup-node.sh --cpu-only`. Setup recreates the containers in their
shared bridge namespace while preserving the Prometheus Agent volume.

New servers normally appear in Grafana within 30 seconds.

With the default ports, the central and node stacks can run on the same host
without port conflicts. If central is bound to `0.0.0.0`, do not set
`GRAFANA_PORT=9095` because the node Agent already publishes that port on
loopback.

Node setup also reads Docker's actual data directory from `docker info` and
mounts that directory read-only into cAdvisor. Custom Docker roots therefore
need no manual Compose edits, and missing paths are never created silently.
On GPU nodes it also starts a temporary DCGM Exporter container and runs
`nvidia-smi -L`, so setup fails before deployment if Docker cannot access the
GPU. All GPU nodes use the same NVIDIA runtime configuration; no per-server
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
sudo ./verify-node.sh
```

Verification requires `curl` and `python3`. A GPU server must report exactly
four `UP` targets; a CPU-only server must report exactly three. The command also
checks that central Prometheus is reachable from the node host.

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

Open Grafana at `http://<central-host>:3000` (or the configured
`GRAFANA_PORT`), then select
**NML → GPU Server Availability**. All provisioned dashboards and their
navigation links default to the latest three hours.

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

On the main overview, **GPU Compute** and **VRAM Usage** show the maximum value
across a server's GPUs at each timestamp; the GPU contributing that maximum can
change over time. Open **Server Details** to inspect fixed per-GPU traces.

The table is ordered for scheduling: Available, Has Capacity, CPU Busy, In Use,
CPU Only, Metrics Missing, then Offline. Its columns are **Server**, **Status**,
**GPU Model**, **GPUs**, **Free**, **GPU Utilization**, **VRAM**, **CPU**,
**Memory**, **GPU Temp**, **CPU Temp**, and **Total VRAM**. Missing values display
as `N/A`; CPU temperature is unavailable when the host exposes no supported
hwmon sensor. Disk usage remains in **Server Details**, and Tailscale IPs are
intentionally omitted. The GPU model summary assumes the GPUs within one server
share a model.

Click a server name in the table to open **Server Details** for the latest three
hours. That view shows per-GPU inventory, compute, VRAM,
temperature and power history, host CPU/RAM/disk history, and the busiest
application containers. Its **Server** selector switches directly between
machines.

**GPU Server Availability · External** is the unfiltered overview intended for
shared displays. It mirrors the main overview, including server drill-down
links, but omits the server selector and shows every server. It still requires
Grafana authentication; this stack does not enable iframe embedding.

## Network and security

No Caddy proxy or application token is used. By default Docker publishes both
central ports only on the detected Tailscale address, limiting them to the
private tailnet. Grafana requires its generated administrator password;
Prometheus remote write does not have application-level authentication. Use
Tailscale access controls so monitored servers can reach TCP `9090` and only
administrators can reach Grafana TCP `GRAFANA_PORT` (`3000` by default).

If Tailscale is unavailable or you explicitly bind to `0.0.0.0`, restrict both
ports and use the setup only on a trusted private LAN. On Linux, Docker-published
ports can bypass ordinary UFW rules. Apply restrictions through your upstream
network firewall or the filtering mechanism appropriate for Docker's configured
firewall backend; see Docker's
[packet-filtering and firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

| Listener | Binding | Purpose |
|---|---|---|
| `9090/tcp` | Docker-published on central `CENTRAL_BIND_ADDRESS` | Prometheus API and remote write |
| `GRAFANA_PORT` (`3000/tcp` by default) | Docker-published on central `CENTRAL_BIND_ADDRESS` | Grafana |
| `9095/tcp` | Docker-published on node `127.0.0.1` | Prometheus Agent status |
| `9100/tcp` | node container loopback only | Node Exporter |
| `18080/tcp` | node container loopback only | cAdvisor |
| `9400/tcp` | node container loopback only | DCGM Exporter |

The Agent status mapping uses host loopback. Docker Engine releases older than
28.0 have a known limitation that can make loopback-published ports reachable
from the same layer-2 network; see Docker's
[port-publishing documentation](https://docs.docker.com/engine/network/port-publishing/).

The central stack uses one network namespace on Docker's existing built-in
`bridge`. Each node stack also uses one shared namespace on that bridge.
Compose does not create project networks or allocate additional subnets. This
avoids allocating subnets from Docker's `default-address-pools` and cannot
trigger Compose subnet exhaustion from this stack. Other Docker research
projects can still create bridge networks and must follow your site's
address-pool rule.

This use of Docker's built-in bridge is intentional because the host cannot
allocate another subnet. Unlike a user-defined bridge, the default bridge gives
weaker isolation from unrelated containers attached to it. Use this deployment
only when other containers on the Docker host are trusted.

Provisioned dashboards are read-only in Grafana. Edit the JSON files in
`central/grafana/dashboards/` to make durable changes; Grafana scans those files
for updates every 30 seconds.

The Docker-published central ports and node Agent status port must be free on
their configured host addresses. Existing Nginx is unaffected unless it already
listens on one of those exact address/port combinations.

## Common commands

```bash
# Update central containers (also refreshes generated network settings)
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
