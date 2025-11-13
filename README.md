# Automatic Kubelet Reservation Configuration

> Bash script that dynamically configures `system-reserved` and `kube-reserved` on Kubernetes v1.32+ nodes.

[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.32-blue.svg)](https://kubernetes.io/)
[![Bash](https://img.shields.io/badge/bash-5.0+-green.svg)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 📋 Table of contents

- [Overview](#-overview)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [Usage](#-usage)
- [Available profiles](#-available-profiles)
- [Density factor](#%EF%B8%8F-density-factor)
- [Usage examples](#-usage-examples)
- [Cluster deployment](#-cluster-deployment)
- [Post deployment validation](#-post-deployment-validation)
- [Rollback](#-rollback)
- [FAQ](#-faq)
- [Troubleshooting](#-troubleshooting)
- [Monitoring and metrics](#-monitoring-and-metrics)
- [Security and best practices](#-security-and-best-practices)
- [Additional resources](#-additional-resources)
- [Contribution](#-contribution)
- [Changelog and release notes](#-changelog-and-release-notes)
- [License](#-license)
- [Support](#-support)
- [Credits](#-credits)

---

## 🎯 Overview

The script automates kubelet reservation sizing. It:

- ✅ **Detects** current node resources (vCPU, RAM, cgroup mode).
- ✅ **Calculates** system and kube reservations using production proven formulas (GKE, EKS, OpenShift).
- ✅ **Adapts** the result based on a desired pod density or a custom density factor.
- ✅ **Generates** a full kubelet configuration file and preserves existing tweaks.
- ✅ **Applies** the configuration with automatic validation, restart and backup/rotation logic.

### Why this script?

Misconfigured reservations often lead to the fastest failure scenarios on Kubernetes:

- Under-sized → OOM kills, eviction storms, `NodeNotReady`.
- Over-sized → Large allocatable drop and wasted capacity.

This script applies the vendor reference formulas and enforces safe guardrails so you can keep nodes stable while maintaining usable capacity.

---

## 🔧 Prerequisites

### Operating system

- Ubuntu 20.04+ with systemd (cgroup v2 ready)
- Linux kernel 5.x+

### Kubernetes

- Kubernetes **v1.26 or newer** (validated on v1.32)
- containerd (recommended) or CRI-O
- `cgroupDriver: systemd`

### Dependencies

The script auto-installs its dependencies (`bc`, `jq`, `yq v4`) during the first run. No manual action is required.

Manual install is possible when internet access is restricted:

```bash
sudo apt update
sudo apt install -y bc jq

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   YQ_BIN=yq_linux_amd64 ;;
  arm64|aarch64)  YQ_BIN=yq_linux_arm64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

sudo wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.44.3/${YQ_BIN}"
sudo chmod +x /usr/local/bin/yq
yq --version
```

> ℹ️ Ubuntu packages ship `yq` v3 (Python) which is not compatible with this project. The script automatically replaces it with the mikefarah v4 binary and validates the SHA256 checksum.

### Permissions

Run the script with root privileges:

```bash
sudo ./kubelet_auto_config.sh
```

---

## 📦 Installation

### Method 1 – direct download

```bash
curl -O https://github.com/MacFlurry/reserved-sys-kube/raw/main/kubelet_auto_config.sh
chmod +x kubelet_auto_config.sh
./kubelet_auto_config.sh --help
```

### Method 2 – Git clone

```bash
git clone https://github.com/MacFlurry/reserved-sys-kube.git
cd reserved-sys-kube
chmod +x kubelet_auto_config.sh rollback-kubelet-config.sh
```

### Method 3 – Push to every node

```bash
NODES="node1 node2 node3"
for node in $NODES; do
  scp kubelet_auto_config.sh root@$node:/usr/local/bin/
  ssh root@$node "chmod +x /usr/local/bin/kubelet_auto_config.sh"
done
```

---

## 🚀 Usage

```bash
sudo ./kubelet_auto_config.sh [OPTIONS]
```

Key options:

| Option | Description |
| --- | --- |
| `--profile <gke|eks|conservative|minimal>` | Reservation model to apply (default: `gke`). |
| `--density-factor <float>` | Directly set the density multiplier (0.1 – 5.0). |
| `--target-pods <int>` | Ask the script to compute a density factor that satisfies a target pod count. |
| `--node-type <control-plane|worker|auto>` | Force the node role (default: auto-detection). |
| `--backup` | Preserve timestamped backups instead of rotating them only. |
| `--dry-run` | Generate the config, display it, but do not apply it. |
| `--no-require-deps` | Continue even if dependencies cannot be installed (lab only). |
| `--wait-timeout <seconds>` | Custom kubelet restart timeout (default 60). |

The script is idempotent: running it again overwrites the configuration with the latest calculation while preserving existing custom sections.

---

## 🧩 Available profiles

- **gke** – Google reference formulas (balanced CPU/memory).
- **eks** – Amazon reference formulas with extra CPU for AWS services.
- **conservative** – Maximum isolation for noisy neighbors and best effort workloads.
- **minimal** – Only safeguard resources for kubelet and core system daemons (useful for small workers or edge nodes).

Each profile can be combined with a density factor or target pod count to match your workload patterns.

---

## ⚖️ Density factor

`density-factor` acts as an additional multiplier on top of the chosen profile. It enables three typical workflows:

1. **Target pods:** `--target-pods 110` computes a safe multiplier to keep allocatable in check for that target.
2. **Manual multiplier:** `--density-factor 1.25` increases every reservation by 25%.
3. **Safety rails:** The script prevents impossible combinations (e.g., reservations >= capacity) and fails fast with a clear message.

Recommendations:

- Control-plane nodes: keep the density factor ≤ 1.0 to leave headroom for static pods.
- High density workers: start around 1.2 and adjust using the post deployment validation commands.

---

## 📎 Usage examples

```bash
# Minimal configuration on a worker
sudo ./kubelet_auto_config.sh --profile minimal

# Conservative profile with automatic pods target
sudo ./kubelet_auto_config.sh --profile conservative --target-pods 80

# Control-plane enforcement with backup
sudo ./kubelet_auto_config.sh --node-type control-plane --backup

# Dry run with explicit density
sudo ./kubelet_auto_config.sh --density-factor 1.4 --dry-run
```

---

## 🛠️ Cluster deployment

1. Copy the script to every node (see installation section).
2. Execute it with the desired parameters.
3. Watch the logs with `journalctl -u kubelet -f`.
4. Confirm allocatable and taints using `kubectl describe node <name>`.

For large fleets consider using an Ansible playbook or a DaemonSet that wraps the script (samples are provided under `ansible/` and `daemonset/`).

---

## ✅ Post deployment validation

Run the following commands after every rollout:

```bash
kubectl get nodes
kubectl describe node <name> | grep -A3 Allocatable
journalctl -u kubelet -n 100
sudo systemd-cgls | grep -E "kubelet|kubepods"
```

Confirm that:

- `system-reserved` and `kube-reserved` match the expected values.
- The kubelet process runs inside `kubelet.slice` (the script configures a drop-in if necessary).
- Pods remain schedulable and the cluster reaches `Ready` state.

---

## 🌀 Rollback

Use `rollback-kubelet-config.sh` to restore a previous version:

```bash
sudo ./rollback-kubelet-config.sh             # restore the latest rotating backup
sudo ./rollback-kubelet-config.sh --index 2   # restore `.last-success.2`
sudo ./rollback-kubelet-config.sh --dry-run   # preview
```

Features:

- Rotating backups: `/var/lib/kubelet/config.yaml.last-success.{0..3}`
- Permanent backups when `--backup` is passed: `/var/lib/kubelet/config.yaml.backup.YYYYMMDD_HHMMSS`
- Safety checks ensure the selected file exists and is readable before copying.

---

## ❓ FAQ

**Q. Do I have to stop the kubelet manually?**  
No. The script restarts it and waits up to the configured timeout.

**Q. Does it work on ARM nodes?**  
Yes. Calculations rely on `bc` and normalized integers to avoid arithmetic issues observed on ARM64.

**Q. Can I version the generated config?**  
Yes, the script only touches `/var/lib/kubelet/config.yaml` and the backup files. Use any configuration management workflow you prefer.

**Q. What about Windows nodes?**  
Not supported. The project targets Linux nodes with systemd.

---

## 🩺 Troubleshooting

| Symptom | Resolution |
| --- | --- |
| `Checksum invalid for yq` | Download the release manually and place it in `/usr/local/bin/yq`. Offline environments often require an internal mirror. |
| `Reservations >= capacity` | Reduce the density factor or select the minimal profile. The node does not expose enough memory for the requested target. |
| `kubelet stuck in activating` | Ensure `/etc/kubernetes/bootstrap-kubelet.conf` and `kubelet.conf` exist. Re-run `kubeadm join` if they were removed. |
| `yq: -i can only be used with -y` | Remove the Python version of `yq`; install mikefarah v4+. |

---

## 📊 Monitoring and metrics

A full monitoring lab lives in `tests/kubelet-alerting-lab/`:

- Helm deployment of kube-prometheus-stack.
- Recording rules for reserving metrics (`kubelet_system_reserved_memory`, etc.).
- Grafana dashboards and recommended alerts.

Launch it from the repo root:

```bash
cd tests/kubelet-alerting-lab
./deploy.sh   # see README for details
```

---

## 🔐 Security and best practices

- Always keep at least one recent backup per node.
- Run the script through a maintenance controller or an automation tool to avoid concurrent executions (the script uses flock for safety but planning ahead helps).
- Track changes in Git: copy `/var/lib/kubelet/config.yaml` into your CMDB or repo after each rollout.
- Combine with admission policies that cap pod density per node pool.

---

## 📚 Additional resources

- [GKE guidance](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-node-resources)
- [EKS resource reservations](https://docs.aws.amazon.com/eks/latest/userguide/managing-kubelet.html)
- [OpenShift node tuning](https://docs.openshift.com/)

---

## 🤝 Contribution

Pull requests are welcome! Please:

1. Open an issue describing the bug or feature.
2. Run the Vagrant lab or the automated tests under `tests/` when adding logic.
3. Keep shellcheck clean (`./tests/quick_tests.sh`).

---

## 🗒️ Changelog and release notes

See `CHANGELOG_v3.0.1.md` for the latest stable release. Historical changelog files live under the `changelog/` directory.

---

## 📄 License

MIT License – see [LICENSE](LICENSE).

---

## 🆘 Support

- GitHub Issues: https://github.com/MacFlurry/reserved-sys-kube/issues

---

## ✨ Credits

Developed and maintained by the Platform Engineering Team. Inspired by the sizing guidance from Google, Amazon, Red Hat, and the Kubernetes SIG Scalability group.
