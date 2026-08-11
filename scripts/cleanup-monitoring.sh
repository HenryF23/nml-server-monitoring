#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

CLEANUP_NAME="cleanup-monitoring.sh"
CLEANUP_DESCRIPTION="Remove host-installed Prometheus and exporter services, packages, configuration, and data."

PACKAGES=(
    prometheus
    prometheus-node-exporter
    node-exporter
    nvidia-gpu-exporter
    nvidia_gpu_exporter
    dcgm-exporter
    nvidia-dcgm-exporter
)

UNITS=(
    prometheus.service
    prometheus-node-exporter.service
    node-exporter.service
    node_exporter.service
    nvidia-gpu-exporter.service
    nvidia_gpu_exporter.service
    dcgm-exporter.service
    nvidia-dcgm-exporter.service
)

PROCESSES=(
    prometheus
    node_exporter
    nvidia_gpu_exporter
    dcgm-exporter
)

PATHS=(
    /etc/prometheus
    /var/lib/prometheus
    /var/log/prometheus
    /var/cache/prometheus
    /opt/prometheus
    /opt/node_exporter
    /opt/nvidia_gpu_exporter
    /usr/local/bin/prometheus
    /usr/local/bin/promtool
    /usr/local/bin/node_exporter
    /usr/local/bin/nvidia_gpu_exporter
    /usr/local/bin/dcgm-exporter
    /etc/default/prometheus
    /etc/default/prometheus-node-exporter
    /etc/default/node-exporter
    /etc/systemd/system/prometheus.service
    /etc/systemd/system/prometheus-node-exporter.service
    /etc/systemd/system/node-exporter.service
    /etc/systemd/system/node_exporter.service
    /etc/systemd/system/nvidia-gpu-exporter.service
    /etc/systemd/system/nvidia_gpu_exporter.service
    /etc/systemd/system/dcgm-exporter.service
    /etc/systemd/system/nvidia-dcgm-exporter.service
)

# NVIDIA drivers, CUDA, NVIDIA Container Toolkit, libdcgm, and
# datacenter-gpu-manager are intentionally not in the removal lists.
source ./cleanup-lib.sh
cleanup_init "$@"
run_cleanup
