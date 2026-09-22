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
  - **Prometheus + Grafana** – Monitoring (Grafana at `http://grafana.local`, Prometheus at `http://prometheus.local`).

The script also supports **stopping** and **starting** the cluster (Docker containers), **uninstalling** optional components, and **teardown** (delete cluster and cleanup).

## Documentation

| Document | Covers |
|----------|--------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Cluster layout, networking, the image registry, storage, memory budget |
| [docs/CICD.md](docs/CICD.md) | How a git push becomes a running pod, stage by stage |
| [docs/ARGOCD.md](docs/ARGOCD.md) | How Argo CD is installed, configured and kept out of trouble |
| [docs/JENKINS.md](docs/JENKINS.md) | How Jenkins is installed, how builds run as pods, why Kaniko |
| [docs/COMPONENTS.md](docs/COMPONENTS.md) | The component registry: adding components, install/suspend/resume/remove |

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
| **6** – Manage components | Per component: install/upgrade, **suspend** (scale to 0 — frees memory, keeps all data), **resume**, or **remove** (helm uninstall + delete namespace). Core is never touched. |
| **7** – Teardown | Delete the cluster and cleanup temp files. All data is lost. |
| **8** – Exit | Quit the script. |

## Local DNS (/etc/hosts)

For ArgoCD, Jenkins, and Grafana to resolve, add to `/etc/hosts`:

```
127.0.0.1  argocd.local
127.0.0.1  jenkins.local
127.0.0.1  grafana.local
127.0.0.1  prometheus.local
```

The script prints a reminder and the exact lines after setup or when adding components.

## Suspend vs remove

**Suspend is the everyday action.** Scaling a component to zero frees its
memory just as completely as uninstalling does, but keeps its PersistentVolume
Claims, configuration and state. Jenkins keeps its jobs, build history, plugins
and credentials; Prometheus keeps its metrics. The original replica counts are
recorded in a `homelab-suspended-replicas` annotation and restored on resume.

**Remove is deliberate and destructive.** It runs `helm uninstall` and deletes
the namespace, taking any PVCs in it with them. Use it to rehearse a clean
install, not to reclaim memory.

Removing Argo CD first strips the `resources-finalizer.argocd.argoproj.io`
finalizer from every Application. Without that the namespace hangs in
`Terminating` forever — Helm has already removed the controller that would
clear the finalizer — and a controller still running would cascade-delete every
workload those Applications manage. Removing Argo CD leaves deployed
applications running.

## Adding a component

Components are rows in the `COMPONENTS` array near the top of `homelab.sh`:

```
key|display|release|namespace|repo_name|repo_url|chart|version|values|hosts
```

Add a row, drop an optional values file in `values/`, and the component appears
in the menus, the status list and the `/etc/hosts` reminder automatically. No
new functions, no menu edits.

Two optional hooks cover anything component-specific:

| Hook | Purpose |
|------|---------|
| `dynamic_values_<key>` | Echo a path to an extra values file, merged after the static one (used to inject Argo CD's bcrypt password hash). |
| `post_install_<key>` | Runs after a successful install — create an Ingress, wait for pods, print credentials. |

Helm values live in `values/` rather than inline in the script, so they can be
reviewed and diffed:

- `values/argocd.yaml`
- `values/jenkins.yaml`
- `values/monitoring.yaml`

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
  Set `ARGOCD_ADMIN_PASSWORD` in a local `.env` (copy `.env.example`) to keep the
  same password across reinstalls — the script bcrypt-hashes it and passes only
  the hash to Helm. `.env` is gitignored; never commit it.
- **Jenkins:** admin / set `JENKINS_ADMIN_PASSWORD` in `.env`. Unset means the
  chart generates a random one — read it from the `jenkins` Secret.
- **Grafana:** admin / set `GRAFANA_ADMIN_PASSWORD` in `.env`.

No password is stored in this repo. All three are read from a local `.env`
(copy `.env.example`), which is gitignored — the script layers them onto the
Helm values at install time so nothing lands in Git.

## Notes

- **MetalLB** uses an IPv4 range derived from the kind Docker network; the script picks the IPv4 subnet and skips IPv6 to avoid invalid pool config.
- **Ingress-Nginx** is scheduled on the control-plane node (label `ingress-ready=true`). The script ensures this label exists so the controller pod can schedule.
- **Metrics-Server** is installed with `--kubelet-insecure-tls` so it works with kind’s kubelet certificates.
- **Stop/Start** only stops/starts the kind node containers; the cluster and data persist until you run **Teardown**.
