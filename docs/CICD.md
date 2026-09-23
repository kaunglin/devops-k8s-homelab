# How CI/CD works

One change to application source, and the running cluster updates itself with
nobody touching `kubectl`. Jenkins builds, the registry stores, Git records,
Argo CD deploys.

## The loop

```
  developer
     │  git push
     ▼
┌──────────────────────┐
│ devops-sample-app    │  source + Dockerfile + Jenkinsfile
└──────────┬───────────┘
           │  Jenkins clones
           ▼
┌──────────────────────┐
│ Jenkins (in-cluster) │  build pod: kaniko + git + jnlp
│  1. resolve tag      │  short git SHA
│  2. kaniko build     │
│  3. push image  ─────┼──────────────┐
│  4. bump tag in Git ─┼───────┐      │
└──────────────────────┘       │      ▼
                               │   ┌──────────────────────┐
                               │   │ homelab-registry     │
                               │   │ sample-app:<sha>     │
                               │   └──────────┬───────────┘
                               ▼              │
                   ┌──────────────────────┐   │
                   │ devops-argocd        │   │
                   │ deployment.yaml      │   │
                   │  image: ...:<sha>    │   │
                   └──────────┬───────────┘   │
                              │ polled ~3 min │
                              ▼               │
                   ┌──────────────────────┐   │
                   │ Argo CD              │   │
                   └──────────┬───────────┘   │
                              │ applies       │ kubelet pulls
                              ▼               ▼
                   ┌──────────────────────────────┐
                   │ sample-app pod running <sha> │
                   └──────────────────────────────┘
```

## The three repositories

| Repo | Holds | Written by |
|------|-------|-----------|
| [devops-sample-app](https://github.com/kaunglin/devops-sample-app) | app source, `Dockerfile`, `Jenkinsfile` | you |
| [devops-argocd](https://github.com/kaunglin/devops-argocd) | Kubernetes manifests, Argo CD `Application`s | you **and Jenkins** |
| [devops-k8s-homelab](https://github.com/kaunglin/devops-k8s-homelab) | the cluster itself, component registry | you |

Source and manifests are separate repos on purpose. It is the standard
two-repo GitOps shape: CI owns the first, CD owns the second, and the only
thing crossing between them is an image tag.

## Stage by stage

### 1. Resolve tag

```groovy
env.TAG = env.GIT_COMMIT.take(7)
```

The image tag is the **short commit SHA** — immutable, and traceable back to
exactly one commit. Never `:latest`: Argo CD cannot detect drift or roll back
against a tag whose meaning changes.

`env.GIT_COMMIT` comes from the SCM checkout rather than running `git`,
because `sh` steps default to the Kaniko container, which has no git binary.

### 2. Build and push

```groovy
container('kaniko') {
  sh '''
    /kaniko/executor \
      --context "$(pwd)" --dockerfile Dockerfile \
      --destination "homelab-registry:5000/sample-app:${TAG}" \
      --build-arg "BUILD_VERSION=${TAG}" \
      --insecure --skip-tls-verify --single-snapshot
  '''
}
```

`BUILD_VERSION` is substituted into `index.html` at build time, so the running
page displays which build it is — the deploy becomes visible in the browser.

Note the address: Kaniko pushes to **`homelab-registry:5000`** because that is
how the registry is reachable from inside the cluster. Manifests reference
**`localhost:5001`**. Both name the same registry; see
[ARCHITECTURE.md](ARCHITECTURE.md#image-registry).

### 3. Bump the tag in Git

```groovy
container('git') {
  withCredentials([usernamePassword(credentialsId: 'github-token', ...)]) {
    sh '''
      git clone --depth 1 "${GITOPS_REPO}" gitops && cd gitops
      sed -i "s#image: localhost:5001/${IMAGE}:.*#image: localhost:5001/${IMAGE}:${TAG}#" "${GITOPS_PATH}"
      git commit -am "sample-app: deploy ${TAG}"
      git push https://${GIT_USER}:${GIT_TOKEN}@github.com/kaunglin/devops-argocd.git HEAD:main
    '''
  }
}
```

This is the step that makes it GitOps. The cluster is never told to deploy;
Git is edited, and the cluster follows. Every deploy is a commit, so `git log`
on the GitOps repo *is* the deployment history.

The `sed` relies on the image line keeping a fixed shape, which is why
`deployment.yaml` writes it as one line.

### 4. Argo CD deploys

Argo CD notices the new commit within ~3 minutes, applies the manifest, and
the kubelet pulls `localhost:5001/sample-app:<sha>` — resolved through
containerd's registry rewrite. A new pod replaces the old one.

## Triggering a build

```bash
cd ~/Kaung/k8s/devops-sample-app
# edit something
git commit -am "change" && git push
```

Then **Build Now** in Jenkins. (Polling or a webhook could automate this;
neither is configured, so builds are started by hand.)

## Verifying each hop

```bash
# 1. image reached the registry
curl -s http://localhost:5001/v2/sample-app/tags/list

# 2. Jenkins committed the tag
cd ~/Kaung/k8s/devops-argocd && git fetch -q && git log origin/main --oneline -3

# 3. Argo CD saw the commit
kubectl get app sample-app -n argocd -o jsonpath='{.status.sync.revision}'

# 4. the cluster is running it
kubectl get deploy sample-app -n sample-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 5. the page says so
curl -s -H 'Host: sample-app.local' http://192.168.97.200/ | grep -o '<div class="v">[^<]*'
```

All five should name the same SHA.

## Expected lag

Argo CD polls every ~3 minutes, so a successful build does not appear in the
UI immediately. It will report `Synced` against the revision it last fetched —
that is not a failure. To deploy at once:

```bash
kubectl patch app sample-app -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `Invalid option type "timestamps"` | Timestamper plugin not installed |
| `git: not found` in a stage | `sh` ran in the Kaniko container — wrap it in `container('git')` |
| `Couldn't find any revision to build` | Branch specifier is `*/master`; should be `*/main` |
| `403 Permission ... denied` on push | Token lacks **Contents: write**, or the repo is outside its scope |
| `401` on push | Wrong or truncated token in the `github-token` credential |
| Kaniko `http: server gave HTTP response to HTTPS client` | `--insecure --skip-tls-verify` missing |
| Argo CD shows an old revision | Has not polled yet — refresh |
| `jenkins-0` stuck `Init:1/2` after a cluster restart | Stale emptyDir — `kubectl delete pod jenkins-0 -n jenkins` (see [JENKINS.md](JENKINS.md)) |
| Pod `ImagePullBackOff` on `localhost:5001/...` | containerd `certs.d` missing on that node |

## What makes this production-shaped

- **Immutable tags.** Every deploy names one commit.
- **Daemonless builds.** No Docker socket mounted anywhere.
- **Git as the source of truth.** The cluster is never imperatively deployed to.
- **Separate CI and CD.** Jenkins cannot deploy; Argo CD cannot build.
- **Auditable history.** `git log` on the GitOps repo is the deploy log.

## What a real environment would add

- A **webhook** instead of polling, and a build trigger instead of *Build Now*
- **Tests** between build and deploy
- **Image scanning** (Trivy) before push
- **Staging and production** as separate Argo CD Applications with promotion
- A registry with **authentication and TLS**
- **Sealed Secrets or Vault**, so secrets live in Git too
