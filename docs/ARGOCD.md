# Argo CD

Argo CD is the **continuous delivery** half of the lab. It watches a Git repo
and makes the cluster match it. Nothing deploys an application except Argo CD.

- Chart `argo-cd` **6.7.18**, Argo CD **v2.10.9**, namespace `argocd`
- UI: **http://argocd.local**, user `admin`
- Source of truth: **https://github.com/kaunglin/devops-argocd**

## How it is installed

Argo CD is a row in the `COMPONENTS` registry in `homelab.sh`:

```
argocd|ArgoCD (GitOps CD)|argocd|argocd|argo|https://argoproj.github.io/argo-helm|argo/argo-cd|6.7.18|argocd.yaml|argocd.local|10m
```

Installing it runs `helm upgrade --install` with `values/argocd.yaml`, then the
`post_install_argocd` hook creates the Ingress and prints the credentials.

### values/argocd.yaml

```yaml
server:
  service:
    type: ClusterIP
configs:
  params:
    server.insecure: true
```

`server.insecure` matters. Argo CD serves HTTPS by default and redirects HTTP
to HTTPS. Nginx already terminates in front of it over plain HTTP at
`argocd.local`, so without this flag the two argue and the browser ends in a
redirect loop.

### Admin password

Set `ARGOCD_ADMIN_PASSWORD` in `devops-k8s-homelab/.env` (gitignored, copied
from `.env.example`). On install the script bcrypt-hashes it with `htpasswd`
and passes only the hash to Helm — the plaintext never reaches Git, the values
file or the Helm release.

**This works only on a fresh install.** Once Argo CD has generated its own
password, `argocd-server` owns `.data.admin.password` in the `argocd-secret`
Secret, and a Helm upgrade fails with:

```
conflict occurred while applying object argocd/argocd-secret:
conflicts with "argocd-server" using v1: .data.admin.password
```

To change the password on a **running** instance, patch the Secret directly:

```bash
HASH=$(htpasswd -nbBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
kubectl -n argocd patch secret argocd-secret -p "{\"stringData\":{
  \"admin.password\":\"${HASH}\",
  \"admin.passwordMtime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
kubectl -n argocd rollout restart deploy/argocd-server
```

Verify by checking `admin.passwordMtime` actually changed — a login test alone
proves nothing if the new password happens to match the old one.

## What Argo CD manages

| Application | Path in devops-argocd | Namespace |
|-------------|----------------------|-----------|
| `sample-app` | `homelab-apps/sample-app` | `sample-app` |
| `shop` | `homelab-apps/shop` | `shop` |

Each is an `Application` manifest in `argocd/`, registered with:

```bash
kubectl apply -f argocd/application-sample-app.yaml
```

Both use HTTPS repo URLs. The repo is public, so no repository credentials are
configured — SSH URLs would require a deploy key.

### Sync policy

```yaml
syncPolicy:
  automated:
    prune: true       # delete resources removed from Git
    selfHeal: true    # revert manual changes to the cluster
  syncOptions:
    - CreateNamespace=true
```

Argo CD polls Git roughly every **3 minutes**. A push is therefore not
deployed instantly. To apply immediately, press **Refresh** in the UI or:

```bash
kubectl patch app sample-app -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

Production would use a webhook instead, but that needs Argo CD reachable from
GitHub, which a local cluster is not.

## Argo CD is stateless

There is no PersistentVolumeClaim. All state lives in:

1. **etcd** — the `Application` and `AppProject` custom resources
2. **Secrets/ConfigMaps** in the `argocd` namespace — repo credentials, config
3. **Git** — the desired state itself

That makes Argo CD disposable. Deleting it leaves every deployed application
running, and re-applying the `Application` manifests afterwards **adopts** the
running resources rather than recreating them: Argo CD matches by
name/namespace/kind, finds they already match Git, and reports Synced with no
restart. Verified by identical pod UIDs across a delete/re-register cycle.

## Protecting data from Argo CD

Two sync options that are easy to confuse:

| Option | Stops |
|--------|-------|
| `Prune=false` | removal when a resource disappears from Git |
| `Delete=false` | removal when the **Application itself** is deleted |

`argocd app delete` uses the cascade finalizer and removes every managed
resource — **including the Namespace**, and with it any Secret that is not in
Git. `Prune=false` alone does not survive that.

Anything holding state therefore carries both:

```yaml
annotations:
  argocd.argoproj.io/sync-options: Prune=false,Delete=false
```

Applied to `shop`'s Namespace and its `db-pvc`. With those set, deleting and
recreating the Application keeps the database and the secrets.

## Gotchas

**`selfHeal: true` fights manual deletion.** Deleting Deployments under a
self-healing app makes Argo CD recreate them within seconds, and a PVC delete
then hangs in `Terminating` waiting for a consumer that keeps respawning.
Disable auto-sync first:

```bash
kubectl patch app <name> -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
#   ... destructive work ...
kubectl patch app <name> -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

**Removing Argo CD needs finalizers stripped first.** Applications carry
`resources-finalizer.argocd.argoproj.io`. Deleting the `argocd` namespace with
those still set hangs it forever — Helm has already removed the controller
that would clear them. `uninstall_component` strips them first, so removing
Argo CD never takes deployed applications down with it.
