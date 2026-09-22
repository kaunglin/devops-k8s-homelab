# Component registry

Every optional component is a row in the `COMPONENTS` array in `homelab.sh`.
Adding one means adding a row and, if it needs configuration, a file under
`values/` — no new functions and no menu edits.

```
key|display|release|namespace|repo_name|repo_url|chart|version|values|hosts|timeout
```

| Field | Meaning |
|-------|---------|
| `key` | internal name, used for hook lookup |
| `display` | what the menu shows |
| `release` | Helm release name (not always the key — monitoring installs as `kube-prometheus-stack`) |
| `namespace` | target namespace, created if absent |
| `repo_name`, `repo_url` | Helm repository |
| `chart`, `version` | pinned chart |
| `values` | file under `values/`, or empty |
| `hosts` | comma-separated `*.local` names, used for the `/etc/hosts` reminder |
| `timeout` | Helm `--wait` timeout |

The menus, the status list and the hosts reminder all build themselves from
this table.

## Hooks

Anything component-specific goes in an optional function rather than the table:

| Hook | Purpose |
|------|---------|
| `dynamic_values_<key>` | Echo a path to an extra values file, merged after the static one. Used to inject Argo CD's bcrypt password hash without putting it in Git. |
| `post_install_<key>` | Runs after a successful install — create an Ingress, wait for pods, print credentials. |

## Lifecycle verbs

```
homelab.sh → 6 → <component> → [i] install  [s] suspend  [r] resume  [x] remove
```

**Suspend is the everyday action.** Scaling every Deployment and StatefulSet
in the namespace to zero frees the memory exactly as completely as
uninstalling, but keeps PVCs, configuration and state. Original replica counts
are recorded in a `homelab-suspended-replicas` annotation and restored on
resume.

**Remove is deliberate and destructive.** `helm uninstall` plus deleting the
namespace, taking any PVCs with it. Use it to rehearse a clean install, not to
reclaim memory. It requires typing `remove` to confirm.

| Component | Recommended | Why |
|-----------|-------------|-----|
| Argo CD | leave running | ~285 MB; stateless, but rebuilding it means re-registering Applications |
| Jenkins | **suspend** | 8 Gi PVC: jobs, history, plugins, credentials |
| Prometheus + Grafana | suspend | PVC of metrics |

## Adding a component

1. Add a row to `COMPONENTS`.
2. Optionally add `values/<name>.yaml`.
3. Optionally add `post_install_<key>` for an Ingress or credentials output.

That is all. Istio, Consul and Vault are three rows whenever they are wanted.

## Install behaviour worth knowing

- A configured values file that **cannot be found aborts the install** rather
  than silently falling back to chart defaults.
- Helm output goes to `/tmp/homelab-helm-<key>.log`, never `/dev/null`, and the
  last lines are printed on failure.
- If Helm fails **after 60 s or more**, the workloads are polled for up to five
  further minutes before giving up — `helm --wait` can time out while a slow
  component (Jenkins downloading plugins) is still converging. A failure faster
  than that is reported as the hard error it is.
