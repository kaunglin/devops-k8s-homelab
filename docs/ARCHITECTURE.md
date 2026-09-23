# Cluster architecture

A local Kubernetes lab built to behave like a production environment: real
upstream Kubernetes, a real ingress controller, real load-balancer IPs, a real
image registry, and GitOps-driven deployment.

## The stack, bottom to top

```
macOS (24 GB)
└── OrbStack VM (12 GB)                    ← the real memory ceiling
    ├── docker network "kind"  192.168.97.0/24
    │   ├── homelab-control-plane  192.168.97.2
    │   ├── homelab-worker         192.168.97.4
    │   ├── homelab-worker2        192.168.97.3
    │   └── homelab-registry       (registry:2, no kubelet — a sibling container)
    └── kind cluster "homelab"   Kubernetes v1.29.0, containerd 1.7.1
```

Each kind "node" is a Docker container running its own kubelet and containerd.
That is why every extra worker costs roughly 300–400 MB: `WORKER_COUNT=1`
drops to a single worker for memory-heavy work.

## Components

| Layer | Component | Chart | Version | Namespace |
|-------|-----------|-------|---------|-----------|
| Load balancer | MetalLB | metallb | 0.14.5 | `metallb-system` |
| Ingress | Ingress-Nginx | ingress-nginx | 4.10.1 | `ingress-nginx` |
| Metrics | Metrics-Server | metrics-server | 3.11.0 | `kube-system` |
| CD | Argo CD | argo-cd | 6.7.18 (v2.10.9) | `argocd` |
| CI | Jenkins | jenkins | 5.9.63 (2.568.3) | `jenkins` |
| Monitoring | kube-prometheus-stack | 59.1.0 | *(optional)* | `monitoring` |

The first three are **core** and always installed. The rest are optional and
managed through the component registry — see [COMPONENTS.md](COMPONENTS.md).

## Networking

Three things cooperate to make `http://something.local` work from the Mac.

**1. MetalLB** assigns LoadBalancer IPs from a pool carved out of the kind
Docker network:

```
kind subnet   192.168.97.0/24
MetalLB pool  192.168.97.200 – 192.168.97.250
```

The pool must live inside the node subnet. Docker Desktop hands out a `/16`
and OrbStack a `/24`, so the pool is derived from the real CIDR prefix rather
than assumed.

**2. Ingress-Nginx** holds the first pool address, `192.168.97.200`, and also
binds hostPort 80/443 on the control-plane node.

**3. OrbStack routes the container network to macOS**, which Docker Desktop
does not. That means MetalLB IPs are reachable directly from the Mac over
TCP — verified with `curl http://192.168.97.200/`. ICMP does not pass, so
`ping` fails; that is expected and not a fault.

### Request path

```
browser → /etc/hosts maps *.local → 127.0.0.1
        → hostPort 80 on the control-plane container
        → ingress-nginx controller
        → matches the Host header against an Ingress rule
        → Service → Pod
```

### Hostnames

| Host | Namespace | Backend |
|------|-----------|---------|
| `argocd.local` | `argocd` | `argocd-server:80` |
| `jenkins.local` | `jenkins` | `jenkins:8080` |
| `sample-app.local` | `sample-app` | `sample-app:80` |
| `legendbits.shop.local` | `shop` | `frontend:80`, `/api` → `backend:8000` |
| `grafana.local`, `prometheus.local` | `monitoring` | *(when installed)* |

All of these need an entry in `/etc/hosts` pointing at `127.0.0.1`.

## Image registry

A `registry:2` container runs **beside** the cluster rather than inside it, so
images survive `kind delete cluster` and do not consume cluster memory.

It answers to two names, which is deliberate:

| From | Address | Used by |
|------|---------|---------|
| macOS | `localhost:5001` | `docker push`, and image refs in manifests |
| inside the cluster | `homelab-registry:5000` | Kaniko when pushing |

containerd on every node rewrites the first to the second:

```toml
# /etc/containerd/certs.d/localhost:5001/hosts.toml
server = "http://homelab-registry:5000"
[host."http://homelab-registry:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

A registry stores images by repository path, not by the hostname used to push,
so both names resolve to identical blobs. Manifests therefore say
`localhost:5001/sample-app:<tag>` and work from either side.

This requires `config_path = "/etc/containerd/certs.d"` under
`[plugins."io.containerd.grpc.v1.cri".registry]` in each node's
`/etc/containerd/config.toml`, followed by a containerd restart.

## Storage

The default StorageClass is `standard`, backed by the local-path provisioner:

| Property | Value | Consequence |
|----------|-------|-------------|
| Provisioner | `rancher.io/local-path` | data lives on **one node's** disk |
| Binding mode | `WaitForFirstConsumer` | the PV is created where the pod first schedules |
| Reclaim policy | `Delete` | deleting the PVC destroys the data |

Two practical consequences:

- A PVC bound to `homelab-worker2` blocks its pod from scheduling if the
  cluster is rebuilt with fewer workers.
- Anything holding data worth keeping should have its PV patched to `Retain`,
  which is what `shop/db-pvc` does.

Current claims:

| Namespace | Claim | Size |
|-----------|-------|------|
| `jenkins` | `jenkins` | 8 Gi — jobs, build history, plugins |
| `shop` | `db-pvc` | 2 Gi — Postgres data *(PV patched to Retain)* |

## Memory budget

The VM ceiling is the real design constraint. Roughly:

| | Approx. |
|---|---|
| 3 kind nodes (kubelet, containerd, etcd, coredns) | ~1.8 GB |
| Argo CD (7 workloads) | ~285 MB |
| Jenkins controller | 1–2 GB |
| Prometheus + Grafana | ~1.5 GB |

Everything cannot run at once, which is why components are suspended rather
than uninstalled — scaling to zero frees the memory while keeping all state.

## Next

- [CICD.md](CICD.md) — how a `git push` becomes a running pod
- [JENKINS.md](JENKINS.md) / [ARGOCD.md](ARGOCD.md) — the build and deploy halves
- [COMPONENTS.md](COMPONENTS.md) — adding, suspending and removing components
