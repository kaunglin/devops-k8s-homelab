# Jenkins

Jenkins is the **continuous integration** half: it builds container images and
pushes them to the local registry. It never talks to the Kubernetes API to
deploy anything — that is Argo CD's job.

- Chart `jenkins` **5.9.63**, Jenkins **2.568.3** (jdk21), namespace `jenkins`
- UI: **http://jenkins.local**, user `admin` (password from `.env`)
- Runs as a StatefulSet with an **8 Gi** PersistentVolumeClaim

## How it is installed

A row in the `COMPONENTS` registry, same as every other component:

```
jenkins|Jenkins (CI)|jenkins|jenkins|jenkins|https://charts.jenkins.io|jenkins/jenkins|5.9.63|jenkins.yaml|jenkins.local|25m
```

The 25-minute timeout is deliberate: Jenkins' first start downloads every
plugin from the update centre, which regularly takes longer than ten minutes.

### values/jenkins.yaml

```yaml
controller:
  admin:
    username: admin
    # password comes from JENKINS_ADMIN_PASSWORD in .env, never from Git
  serviceType: ClusterIP
  resources:
    requests: { cpu: "500m", memory: "1Gi" }
    limits:   { cpu: "1500m", memory: "2Gi" }
  javaOpts: "-Xms512m -Xmx1024m"
  installPlugins:
    - kubernetes:latest            # provisions build agents as pods
    - workflow-aggregator:latest   # declarative pipeline
    - git:latest
    - credentials-binding:latest   # withCredentials() in the Jenkinsfile
    - configuration-as-code:latest
persistence:
  enabled: true
  size: 8Gi
agent:
  enabled: true
```

Two things to know about that file.

**The admin keys moved.** Chart 5.x expects `controller.admin.username` and
`controller.admin.password`. The older `controller.adminUser` /
`controller.adminPassword` are **silently ignored**, which leaves Jenkins with
a randomly generated password instead of the configured one. If the password
is not what you set, check with:

```bash
kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

**Values must actually reach Helm.** Check with
`helm get values jenkins -n jenkins`. If it prints `null`, the release is
running on chart defaults and nothing in this file is in effect — which shows
up as a random admin password and an unexpected PVC size. The installer now
aborts when a configured values file cannot be found, rather than falling back
to defaults silently.

**Plugins float, so the chart must stay current.** Plugins are requested as
`:latest`, and current plugins require Jenkins 2.479–2.504+. Pinning the chart
low breaks the init container with:

```
ssh-credentials requires a greater version of Jenkins (2.479.1) than 2.452.1
```

That is the same `:latest` hazard that applies to image tags, in a different
place. Either keep the chart recent or pin the plugin versions.

### Plugins deliberately absent

| Plugin | Why not |
|--------|---------|
| `docker-workflow` | There is no Docker daemon inside kind. Builds use Kaniko. |
| `blueocean` | Deprecated and heavy for a lab. |
| `timestamper` | Not installed, so `timestamps()` in a pipeline fails to compile. |

## How builds run

The `kubernetes` plugin gives Jenkins no static agents. Every build creates a
**pod** in the `jenkins` namespace, runs the pipeline in it, and deletes it.
The pod spec is declared inline in the Jenkinsfile:

```groovy
agent {
  kubernetes {
    defaultContainer 'kaniko'
    yaml '''
    containers:
      - name: kaniko
        image: gcr.io/kaniko-project/executor:v1.23.2-debug
        command: ["/busybox/cat"]
        tty: true
      - name: git
        image: alpine/git:2.45.2
        command: ["cat"]
        tty: true
    '''
  }
}
```

Jenkins adds a third `jnlp` container automatically — the agent that talks
back to the controller. All three share the workspace volume.

### Why Kaniko instead of docker build

A build pod has no access to a Docker daemon, and mounting the host socket
would be both unavailable and a bad habit. [Kaniko](https://github.com/GoogleContainerTools/kaniko)
builds an image from a Dockerfile entirely in userspace and pushes it straight
to a registry. Against the lab's plain-HTTP registry it needs:

```
--insecure --skip-tls-verify
```

`defaultContainer 'kaniko'` means every `sh` step runs in the Kaniko container
unless wrapped in `container('git') { ... }`. That image is busybox-based and
has **no git binary**, which is why the pipeline reads `env.GIT_COMMIT` rather
than shelling out to `git rev-parse`.

## Credentials

| ID | Kind | Used for |
|----|------|----------|
| `github-token` | Username with password | Pushing the image-tag commit to `devops-argocd` |

Username is the GitHub account; password is a **fine-grained personal access
token** scoped to `devops-argocd` with **Contents: Read and write**.

Read access needs no credential — both repos are public.

Failure modes worth recognising:

| Symptom | Cause |
|---------|-------|
| `401` | Bad or missing credential |
| `403 Permission ... denied` | Token authenticated but lacks **write**, or the repo is not in its scope |

## Job configuration

One Pipeline job, `sample-app`:

- Definition: **Pipeline script from SCM**
- SCM: Git, `https://github.com/kaunglin/devops-sample-app.git`
- Branch specifier: **`*/main`** — the default is `*/master` and will fail with
  "Couldn't find any revision to build"
- Script path: `Jenkinsfile`
- Credentials: none (public repo)

Because the Jenkinsfile lives in the repo, changing the pipeline is a commit —
no job reconfiguration.

## Lifecycle

Jenkins holds real state in its 8 Gi volume: job configuration, build history,
credentials and runtime-installed plugins. **Never remove it to free memory.**
Suspend it instead:

```
homelab.sh → 6 → Jenkins → [s] Suspend
```

Scaling to zero frees the memory just as completely while keeping everything.
Removing it deletes the namespace and the PVC with it.
