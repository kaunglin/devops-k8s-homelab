# devops-k8s-homelab

A single script to run a local Kubernetes homelab on [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker), with MetalLB, Ingress-Nginx, Metrics-Server, and optional apps (ArgoCD, Jenkins, Prometheus + Grafana).

## What the script does

- **Creates a kind cluster** (1 control-plane + 2 workers) with a fixed name (`homelab`).
- **Installs core components** on every setup:
  - **MetalLB** – LoadBalancer services get IPs from the kind Docker network.
  - **Ingress-Nginx** – Ingress controller with hostPort 80/443 and `ingress-ready` node selector.
  - **Metrics-Server** – For `kubectl top nodes` / `kubectl top pods` (uses `--kubelet-insecure-tls` for kind).
- **Optional components** (you choose during setup or when adding components):
  - **ArgoCD** – GitOps CD (UI at `http://argocd.local`).
  - **Jenkins** – CI (UI at `http://jenkins.local`).
  - **Prometheus + Grafana** – Monitoring (Grafana at `http://grafana.local`).

The script also supports **stopping** and **starting** the cluster (Docker containers), **uninstalling** optional components, and **teardown** (delete cluster and cleanup).

## Prerequisites

- **Docker** (Docker Desktop or Engine running).
- **kind** – [Install](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (e.g. `brew install kind`).
- **kubectl** – [Install](https://kubernetes.io/docs/tasks/tools/) (e.g. `brew install kubectl`).
- **Helm 3** – [Install](https://helm.sh/docs/intro/install/) (e.g. `brew install helm`).

The script checks for `docker`, `kind`, `kubectl`, and `helm` and suggests Homebrew install commands if any are missing.

## How to run

```bash
chmod +x homelab.sh
./homelab.sh
```

You get an interactive menu. Cluster status (RUNNING / STOPPED / NOT RUNNING) is shown at the top.

## Menu options

| Option | Description |
|--------|-------------|
| **1** – Setup new cluster | Create the kind cluster, install core (MetalLB, Ingress-Nginx, Metrics-Server), then prompt for optional components (ArgoCD, Jenkins, Prometheus + Grafana). |
| **2** – Add components | Use existing cluster; ensure core is installed, then choose and install optional components. |
| **3** – Show cluster status | Nodes, `kubectl top nodes`, `kubectl top pods -A`, non-Running pods, LoadBalancer services. |
| **4** – Stop cluster | Stop the kind node containers (cluster persists; use Start to resume). |
| **5** – Start cluster | Start the kind node containers and wait for nodes to be Ready. |
| **6** – Uninstall optional components | Remove ArgoCD, Jenkins, and/or Prometheus + Grafana (and their namespaces). Core is not removed. |
| **7** – Teardown | Delete the cluster and cleanup temp files. All data is lost. |
| **8** – Exit | Quit the script. |

## Local DNS (/etc/hosts)

For ArgoCD, Jenkins, and Grafana to resolve, add to `/etc/hosts`:

```
127.0.0.1  argocd.local
127.0.0.1  jenkins.local
127.0.0.1  grafana.local
```

The script prints a reminder and the exact lines after setup or when adding components.

## Configuration

At the top of `homelab.sh` you can change:

- **Cluster:** `CLUSTER_NAME`, `K8S_VERSION`
- **Helm chart versions:** `METALLB_VERSION`, `INGRESS_NGINX_VERSION`, `METRICS_SERVER_VERSION`, `ARGOCD_HELM_VERSION`, `JENKINS_HELM_VERSION`, `PROM_STACK_HELM_VERSION`
- **Namespaces:** `NS_METALLB`, `NS_INGRESS`, `NS_METRICS`, `NS_ARGOCD`, `NS_JENKINS`, `NS_MONITORING`

Default cluster name is `homelab`; kubectl context is `kind-homelab`.

## Logs

When you run **Setup**, **Add components**, or **Teardown**, the script writes a timestamped log file under `/tmp`, e.g.:

- `/tmp/homelab-YYYYMMDD-HHMMSS.log`

The path is printed at the start. Helm and key commands are logged so you can troubleshoot failures.

## Default credentials (optional components)

- **ArgoCD:** admin / (password from `argocd-initial-admin-secret`).
- **Jenkins:** admin / `homelab123`.
- **Grafana:** admin / `homelab123`.

Change these in the script or in the cluster if you need different passwords.

## Notes

- **MetalLB** uses an IPv4 range derived from the kind Docker network; the script picks the IPv4 subnet and skips IPv6 to avoid invalid pool config.
- **Ingress-Nginx** is scheduled on the control-plane node (label `ingress-ready=true`). The script ensures this label exists so the controller pod can schedule.
- **Metrics-Server** is installed with `--kubelet-insecure-tls` so it works with kind’s kubelet certificates.
- **Stop/Start** only stops/starts the kind node containers; the cluster and data persist until you run **Teardown**.
