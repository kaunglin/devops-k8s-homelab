# Documentation

A local Kubernetes lab built to behave like a production environment: real
upstream Kubernetes, a real ingress controller, a real image registry, Jenkins
for CI and Argo CD for CD.

## Where to start

Read in this order the first time:

| # | Document | Answers |
|---|----------|---------|
| 1 | [ARCHITECTURE.md](ARCHITECTURE.md) | What is running, how traffic reaches it, where images and data live |
| 2 | [CICD.md](CICD.md) | How a `git push` becomes a running pod |
| 3 | [JENKINS.md](JENKINS.md) | How the build half works |
| 4 | [ARGOCD.md](ARGOCD.md) | How the deploy half works |
| 5 | [COMPONENTS.md](COMPONENTS.md) | How to add, suspend or remove a component |

## The three repositories

| Repo | Holds | Written by |
|------|-------|-----------|
| [devops-sample-app](https://github.com/kaunglin/devops-sample-app) | application source, `Dockerfile`, `Jenkinsfile` | you |
| [devops-argocd](https://github.com/kaunglin/devops-argocd) | Kubernetes manifests, Argo CD `Application`s | you **and Jenkins** |
| **devops-k8s-homelab** (this repo) | the cluster itself, component registry, these docs | you |

Source and manifests are deliberately separate: CI owns the first repo, CD owns
the second, and the only thing crossing between them is an image tag.

## Quick answers

| Question | Where |
|----------|-------|
| Why is `sample-app.local` not resolving? | [ARCHITECTURE.md → Networking](ARCHITECTURE.md#networking) |
| Why two names for one registry? | [ARCHITECTURE.md → Image registry](ARCHITECTURE.md#image-registry) |
| Does a push build automatically? | [CICD.md → Triggering a build](CICD.md#triggering-a-build) — no, builds are manual |
| A pipeline stage failed | [CICD.md → Troubleshooting](CICD.md#troubleshooting) |
| Jenkins stuck `Init:1/2` after a restart | [JENKINS.md](JENKINS.md#after-a-cluster-stopstart-init-container-back-off) |
| Where do passwords live? | A gitignored `.env` — see [ARGOCD.md](ARGOCD.md#admin-password) and [JENKINS.md](JENKINS.md#credentials) |
| How do I free memory? | Suspend, don't remove — [COMPONENTS.md](COMPONENTS.md#lifecycle-verbs) |
