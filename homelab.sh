#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
#  COLORS & SYMBOLS
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OK="${GREEN}✔${NC}"
FAIL="${RED}✘${NC}"
INFO="${CYAN}➜${NC}"
WARN="${YELLOW}⚠${NC}"

# ─────────────────────────────────────────────
#  CONFIGURATION (edit versions here)
# ─────────────────────────────────────────────
CLUSTER_NAME="homelab"
K8S_VERSION="v1.29.0"

# Number of worker nodes. Each kind node is a container running its own
# kubelet/containerd, so every extra worker costs ~300-400MB. Drop to 1 when
# running heavy stacks (Istio, Vault, Consul) on a memory-constrained VM:
#   WORKER_COUNT=1 ./homelab.sh
WORKER_COUNT="${WORKER_COUNT:-2}"

# Local overrides, never committed (.env is gitignored). Set
# ARGOCD_ADMIN_PASSWORD there to keep one Argo CD admin password across
# reinstalls instead of a fresh random one each time. See .env.example.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# Address that external machines/VMs use to reach the API server.
# OrbStack assigns every container a routable *.orb.local domain that is
# reachable from other OrbStack machines, so we default to the control-plane
# container's domain. Override with API_SERVER_HOST=<ip-or-host> if you'd
# rather connect via the Mac's LAN IP or another address.
API_SERVER_HOST="${API_SERVER_HOST:-${CLUSTER_NAME}-control-plane.orb.local}"

METALLB_VERSION="0.14.5"
INGRESS_NGINX_VERSION="4.10.1"
METRICS_SERVER_VERSION="3.11.0"
ARGOCD_HELM_VERSION="6.7.18"
JENKINS_HELM_VERSION="5.9.63"
PROM_STACK_HELM_VERSION="91.5.0"

NS_METALLB="metallb-system"
NS_INGRESS="ingress-nginx"
NS_METRICS="kube-system"
NS_ARGOCD="argocd"
NS_JENKINS="jenkins"
NS_MONITORING="monitoring"

# Log file (set when running setup/add/teardown)
LOG_FILE=""

# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────
log() {
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "${LOG_FILE:-}" && -n "$LOG_FILE" ]]; then
    echo "[$ts] $msg" >> "$LOG_FILE"
  fi
  echo -e "  ${BLUE}[$ts]${NC} $msg"
}
print_banner() {
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║       🏠  Homelab K8s Manager            ║${NC}"
  echo -e "${BOLD}${BLUE}║   kind + MetalLB + Nginx + Optional Apps ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}────────────────────────────────────────${NC}"
}

success() { echo -e "  ${OK}  $1"; }
info()    { echo -e "  ${INFO}  $1"; }
warn()    { echo -e "  ${WARN}  $1"; }
fail()    { echo -e "  ${FAIL}  ${RED}$1${NC}"; }

wait_for_pods() {
  local namespace=$1
  local label=$2
  local timeout=${3:-180}
  info "Waiting for pods in ${namespace} (label: ${label})..."
  log "Waiting for pods in ${namespace} (selector=${label}, timeout=${timeout}s)"
  kubectl wait pod \
    --namespace "${namespace}" \
    --selector="${label}" \
    --for=condition=Ready \
    --timeout="${timeout}s" 2>/dev/null && \
    success "Pods ready in ${namespace}" || \
    warn "Some pods in ${namespace} took longer than expected — check manually"
}

ensure_namespace() {
  kubectl get namespace "$1" &>/dev/null || kubectl create namespace "$1" &>/dev/null
}

# ─────────────────────────────────────────────
#  DEPENDENCY CHECK
# ─────────────────────────────────────────────
check_dependencies() {
  print_section "Checking Dependencies"
  local missing=()
  for cmd in docker kind kubectl helm; do
    if command -v "$cmd" &>/dev/null; then
      success "$cmd found ($(${cmd} version --short 2>/dev/null | head -1 || ${cmd} --version 2>/dev/null | head -1))"
    else
      fail "$cmd not found"
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    warn "Missing tools: ${missing[*]}"
    echo -e "  Install with Homebrew:"
    for tool in "${missing[@]}"; do
      echo -e "    ${YELLOW}brew install ${tool}${NC}"
    done
    echo ""
    exit 1
  fi

  # Check Docker is running
  if ! docker info &>/dev/null; then
    fail "Docker daemon is not running. Start Docker Desktop first."
    exit 1
  fi
  success "Docker daemon is running"
}

# ─────────────────────────────────────────────
#  KIND CLUSTER CONFIG
# ─────────────────────────────────────────────
create_kind_config() {
  log "Writing kind config to /tmp/kind-homelab.yaml"
  cat <<EOF > /tmp/kind-homelab.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
      - |
        kind: ClusterConfiguration
        apiServer:
          certSANs:
            - "localhost"
            - "127.0.0.1"
            - "0.0.0.0"
            - "host.docker.internal"
            - "${API_SERVER_HOST}"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF

  # Worker nodes (WORKER_COUNT of them), each with its own /data host mount
  local i
  for (( i=1; i<=WORKER_COUNT; i++ )); do
    cat <<EOF >> /tmp/kind-homelab.yaml
  - role: worker
    extraMounts:
      - hostPath: /tmp/kind-worker${i}
        containerPath: /data
EOF
    mkdir -p "/tmp/kind-worker${i}"
  done

  cat <<EOF >> /tmp/kind-homelab.yaml
networking:
  # Bind the API server to all host interfaces so it is reachable from
  # other machines/VMs (e.g. OrbStack), not just the host's loopback.
  apiServerAddress: "0.0.0.0"
  apiServerPort: 6443
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF
  log "Kind config created (workers: ${WORKER_COUNT}, podSubnet: 10.244.0.0/16, serviceSubnet: 10.96.0.0/12)"
}

# ─────────────────────────────────────────────
#  METALLB IP RANGE
# ─────────────────────────────────────────────
get_metallb_ip_range() {
  # Get the kind Docker network subnet(s). Use IPv4 only (MetalLB pool must be IPv4 for kind).
  # Docker may return multiple subnets (e.g. IPv4 + IPv6) with no separator in default format.
  local subnets
  subnets=$(docker network inspect kind \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null) || true

  local subnet
  subnet=$(echo "$subnets" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -1)
  if [[ -z "$subnet" ]]; then
    # Fallback if no IPv4 found (e.g. kind not running)
    subnet="172.18.0.0/16"
  fi

  # Carve the pool out of the *same* subnet the kind network actually uses.
  # Docker Desktop hands out a /16 (172.18.0.0/16); OrbStack hands out a /24
  # (e.g. 192.168.97.0/24), so the third octet cannot be hardcoded to 255.
  local base prefix o1 o2 o3
  base=${subnet%/*}
  prefix=${subnet#*/}
  IFS='.' read -r o1 o2 o3 _ <<< "$base"

  if (( prefix >= 24 )); then
    # /24 or narrower: take the top of the subnet's own third octet
    echo "${o1}.${o2}.${o3}.200-${o1}.${o2}.${o3}.250"
  else
    # wider than /24: use the last /24 block of the range
    echo "${o1}.${o2}.255.200-${o1}.${o2}.255.250"
  fi
}

# ─────────────────────────────────────────────
#  INSTALL CORE (MetalLB + Ingress-Nginx)
# ─────────────────────────────────────────────
install_metallb() {
  print_section "Installing MetalLB"
  log "Installing MetalLB (Helm repo add/update)"

  helm repo add metallb https://metallb.github.io/metallb --force-update &>/dev/null
  helm repo update &>/dev/null

  ensure_namespace "$NS_METALLB"
  log "Namespace $NS_METALLB ensured"

  if helm list -n "$NS_METALLB" -q 2>/dev/null | grep -qx "metallb"; then
    info "MetalLB Helm release already installed, skipping install (will ensure IP pool)"
    log "MetalLB already installed, skipping Helm upgrade to avoid CRD conflicts"
  else
    info "Installing MetalLB Helm chart..."
    log "Running: helm upgrade --install metallb (timeout 4m)"
    helm upgrade --install metallb metallb/metallb \
      --namespace "$NS_METALLB" \
      --version "$METALLB_VERSION" \
      --wait \
      --timeout 4m 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      fail "MetalLB Helm install failed. Check the error above."
      exit 1
    fi
    success "MetalLB Helm chart installed"
    log "MetalLB Helm chart installed successfully"

    # Wait for MetalLB webhook to be ready before applying config
    log "Waiting 10s for MetalLB webhook to be ready..."
    sleep 10
  fi

  local ip_range
  ip_range=$(get_metallb_ip_range)
  info "Configuring MetalLB IP pool: ${ip_range}"
  log "Applying MetalLB IP pool: ${ip_range}"

  if ! kubectl apply -f - <<EOF; then
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: ${NS_METALLB}
spec:
  addresses:
    - ${ip_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: ${NS_METALLB}
spec:
  ipAddressPools:
    - homelab-pool
EOF
    fail "MetalLB IP pool configuration failed."
    exit 1
  fi
  success "MetalLB IP pool configured (${ip_range})"
}

# Ensure control-plane node has ingress-ready label so ingress-nginx controller can schedule
ensure_ingress_ready_label() {
  local cp_node
  cp_node=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$cp_node" ]]; then
    kubectl label nodes "$cp_node" ingress-ready=true --overwrite 2>/dev/null && \
      log "Labeled control-plane node $cp_node with ingress-ready=true" || true
  fi
}

install_ingress_nginx() {
  print_section "Installing Ingress-Nginx"
  log "Installing Ingress-Nginx (Helm repo add/update)"

  # So controller can schedule on control-plane (needs ingress-ready=true)
  ensure_ingress_ready_label

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update &>/dev/null
  helm repo update &>/dev/null

  ensure_namespace "$NS_INGRESS"
  log "Namespace $NS_INGRESS ensured"

  if helm list -n "$NS_INGRESS" -q 2>/dev/null | grep -qx "ingress-nginx"; then
    info "Ingress-Nginx Helm release already installed, skipping install"
    log "Ingress-Nginx already installed, skipping Helm upgrade"
    wait_for_pods "$NS_INGRESS" "app.kubernetes.io/component=controller" 30
  else
    info "Installing ingress-nginx Helm chart (this may take a few minutes)..."
    log "Running: helm upgrade --install ingress-nginx (timeout 5m)"
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace "$NS_INGRESS" \
      --version "$INGRESS_NGINX_VERSION" \
      --set-string controller.nodeSelector."ingress-ready"="true" \
      --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
      --set controller.tolerations[0].operator="Equal" \
      --set controller.tolerations[0].effect="NoSchedule" \
      --set controller.hostPort.enabled=true \
      --set controller.service.type=LoadBalancer \
      --set controller.updateStrategy.rollingUpdate.maxSurge=0 \
      --set controller.updateStrategy.rollingUpdate.maxUnavailable=1 \
      --set controller.metrics.enabled=true \
      --set controller.metrics.serviceMonitor.enabled=true \
      --set controller.metrics.serviceMonitor.additionalLabels.release=kube-prometheus-stack \
      --wait \
      --timeout 5m 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
      fail "Ingress-Nginx Helm install failed. Check the error above."
      exit 1
    fi
    success "Ingress-Nginx installed"
    log "Ingress-Nginx Helm chart installed successfully"

    wait_for_pods "$NS_INGRESS" "app.kubernetes.io/component=controller" 120
    log "Ingress-Nginx controller pods ready"
  fi

  # Show controller pod status so user can confirm pods exist
  info "Ingress-Nginx controller pods:"
  kubectl get pods -n "$NS_INGRESS" -l app.kubernetes.io/component=controller -o wide 2>/dev/null || true
}

# ─────────────────────────────────────────────
#  METRICS-SERVER (core)
# ─────────────────────────────────────────────
install_metrics_server() {
  print_section "Installing Metrics-Server"

  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update &>/dev/null
  helm repo update &>/dev/null

  log "Installing metrics-server (kubelet-insecure-tls for kind)"

  if helm list -n "$NS_METRICS" -q 2>/dev/null | grep -qx "metrics-server"; then
    info "Metrics-server Helm release already installed, skipping"
    log "Metrics-server already installed, skipping"
    return 0
  fi

  helm upgrade --install metrics-server metrics-server/metrics-server \
    --namespace "$NS_METRICS" \
    --version "$METRICS_SERVER_VERSION" \
    --set args[0]=--kubelet-insecure-tls \
    --wait \
    --timeout 3m 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    fail "Metrics-server Helm install failed. Check the error above."
    exit 1
  fi
  success "Metrics-server installed (kubectl top nodes/pods will work after it is ready)"
  log "Metrics-server installed"
}

# ─────────────────────────────────────────────
#  COMPONENT REGISTRY
# ─────────────────────────────────────────────
# One row per optional component. Adding a component means adding a row here
# and, if it needs configuration, a file under values/ — no new functions and
# no menu edits. Anything component-specific goes in an optional hook:
#   dynamic_values_<key>   echo a path to an extra values file (merged last)
#   post_install_<key>     runs after a successful install
#
#   key|display|release|namespace|repo_name|repo_url|chart|version|values|hosts|timeout
COMPONENTS=(
  "argocd|ArgoCD (GitOps CD)|argocd|${NS_ARGOCD}|argo|https://argoproj.github.io/argo-helm|argo/argo-cd|${ARGOCD_HELM_VERSION}|argocd.yaml|argocd.local|10m"
  "jenkins|Jenkins (CI)|jenkins|${NS_JENKINS}|jenkins|https://charts.jenkins.io|jenkins/jenkins|${JENKINS_HELM_VERSION}|jenkins.yaml|jenkins.local|25m"
  "monitoring|kube-prometheus-stack (Prometheus + Grafana)|kube-prometheus-stack|${NS_MONITORING}|prometheus-community|https://prometheus-community.github.io/helm-charts|prometheus-community/kube-prometheus-stack|${PROM_STACK_HELM_VERSION}|monitoring.yaml|grafana.local,prometheus.local|15m"
)

# Annotation used to remember replica counts across a suspend/resume cycle.
SUSPEND_ANNOTATION="homelab-suspended-replicas"

# Set by select_components; consumed by setup_cluster / add_components.
SELECTED_COMPONENTS=""

component_keys() {
  local row
  for row in "${COMPONENTS[@]}"; do echo "${row%%|*}"; done
}

component_field() {  # $1=key  $2=1-based field index
  local key=$1 idx=$2 row
  for row in "${COMPONENTS[@]}"; do
    if [[ "${row%%|*}" == "$key" ]]; then
      echo "$row" | cut -d'|' -f"$idx"
      return 0
    fi
  done
  return 1
}

component_key_at() {  # $1=1-based menu position
  component_keys | sed -n "${1}p"
}

# installed | suspended | absent
component_status() {
  local key=$1 ns release running
  release=$(component_field "$key" 3)
  ns=$(component_field "$key" 4)
  if ! helm list -n "$ns" -q 2>/dev/null | grep -qx "$release"; then
    echo "absent"; return 0
  fi
  running=$(kubectl get deploy,statefulset -n "$ns" \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null | grep -vx '0' | head -1)
  if [[ -z "$running" ]]; then echo "suspended"; else echo "installed"; fi
}

component_status_label() {
  case "$(component_status "$1")" in
    installed) echo -e "${GREEN}INSTALLED${NC}" ;;
    suspended) echo -e "${YELLOW}SUSPENDED${NC}" ;;
    *)         echo -e "${RED}NOT INSTALLED${NC}" ;;
  esac
}

component_hosts() {  # every *.local host this component serves, one per line
  component_field "$1" 10 | tr ',' '\n' | grep -v '^$' || true
}

# ─────────────────────────────────────────────
#  COMPONENT-SPECIFIC HOOKS
# ─────────────────────────────────────────────
# Argo CD's admin password: bcrypt the plaintext from .env and hand Helm only
# the hash. Without ARGOCD_ADMIN_PASSWORD, Argo CD keeps its random default.
dynamic_values_argocd() {
  [[ -z "${ARGOCD_ADMIN_PASSWORD:-}" ]] && return 0
  if ! command -v htpasswd &>/dev/null; then
    warn "htpasswd not found - falling back to ArgoCD's random password" >&2
    return 0
  fi
  local pw_hash pw_mtime out=/tmp/homelab-argocd-secret.yaml
  pw_hash=$(htpasswd -nbBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/^\$2y/\$2a/')
  pw_mtime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat <<EOF > "$out"
configs:
  secret:
    argocdServerAdminPassword: "${pw_hash}"
    argocdServerAdminPasswordMtime: "${pw_mtime}"
EOF
  echo "$out"
}

# Jenkins' chart takes the admin password as a plain value, so it is layered
# in from .env at install time rather than committed. Unset means the chart
# generates a random one, readable from the jenkins Secret.
dynamic_values_jenkins() {
  [[ -z "${JENKINS_ADMIN_PASSWORD:-}" ]] && return 0
  local out=/tmp/homelab-jenkins-secret.yaml
  cat <<EOF > "$out"
controller:
  admin:
    password: "${JENKINS_ADMIN_PASSWORD}"
EOF
  echo "$out"
}

# Same for Grafana. The chart only applies this on a fresh install; an
# existing Grafana keeps whatever is in its own user database.
dynamic_values_monitoring() {
  [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]] && return 0
  local out=/tmp/homelab-grafana-secret.yaml
  cat <<EOF > "$out"
grafana:
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
EOF
  echo "$out"
}

create_ingress() {  # $1=name $2=namespace $3=host $4=service $5=port
  kubectl apply -f - <<EOF &>/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $1
  namespace: $2
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
    - host: $3
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $4
                port:
                  number: $5
EOF
}

post_install_argocd() {
  create_ingress argocd-ingress "$NS_ARGOCD" argocd.local argocd-server 80
  wait_for_pods "$NS_ARGOCD" "app.kubernetes.io/name=argocd-server" 180
  local pass
  if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]] && command -v htpasswd &>/dev/null; then
    pass="(ARGOCD_ADMIN_PASSWORD from .env - stable across reinstalls)"
  else
    pass=$(kubectl -n "$NS_ARGOCD" get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null \
      || echo "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
  fi
  echo ""
  echo -e "    ${BOLD}ArgoCD:${NC}  ${YELLOW}http://argocd.local${NC}  admin / ${YELLOW}${pass}${NC}"
}

post_install_jenkins() {
  create_ingress jenkins-ingress "$NS_JENKINS" jenkins.local jenkins 8080
  wait_for_pods "$NS_JENKINS" "app.kubernetes.io/component=jenkins-controller" 300
  echo ""
  local jpass
  if [[ -n "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
    jpass="(JENKINS_ADMIN_PASSWORD from .env)"
  else
    jpass=$(kubectl get secret jenkins -n "$NS_JENKINS" -o jsonpath='{.data.jenkins-admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "see the jenkins Secret")
  fi
  echo -e "    ${BOLD}Jenkins:${NC} ${YELLOW}http://jenkins.local${NC}  admin / ${YELLOW}${jpass}${NC}"
}

post_install_monitoring() {
  # Grafana and Prometheus ingresses come from values/monitoring.yaml
  wait_for_pods "$NS_MONITORING" "app.kubernetes.io/name=grafana" 180
  echo ""
  local gpass
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    gpass="(GRAFANA_ADMIN_PASSWORD from .env)"
  else
    gpass=$(kubectl get secret kube-prometheus-stack-grafana -n "$NS_MONITORING" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "see the grafana Secret")
  fi
  echo -e "    ${BOLD}Grafana:${NC}    ${YELLOW}http://grafana.local${NC}  admin / ${YELLOW}${gpass}${NC}"
  echo -e "    ${BOLD}Prometheus:${NC} ${YELLOW}http://prometheus.local${NC}"
}

# ─────────────────────────────────────────────
#  INSTALL / SUSPEND / RESUME / REMOVE
# ─────────────────────────────────────────────
install_component() {
  local key=$1
  local display release ns repo_name repo_url chart version values base overlay timeout
  display=$(component_field "$key" 2);  release=$(component_field "$key" 3)
  ns=$(component_field "$key" 4);       repo_name=$(component_field "$key" 5)
  repo_url=$(component_field "$key" 6); chart=$(component_field "$key" 7)
  version=$(component_field "$key" 8);  values=$(component_field "$key" 9)
  timeout=$(component_field "$key" 11); timeout="${timeout:-10m}"

  print_section "Installing ${display}"
  log "Installing ${key} (chart=${chart} version=${version} ns=${ns})"

  helm repo add "$repo_name" "$repo_url" --force-update &>/dev/null
  helm repo update &>/dev/null
  ensure_namespace "$ns"

  base=""
  if [[ -n "$values" ]]; then
    if [[ -f "${SCRIPT_DIR}/values/${values}" ]]; then
      base="${SCRIPT_DIR}/values/${values}"
    else
      # Installing with chart defaults is worse than failing: the component
      # comes up subtly misconfigured and nothing says why.
      fail "values/${values} not found under ${SCRIPT_DIR} - refusing to install ${display} with chart defaults"
      log "${key} install ABORTED: missing values/${values}"
      return 1
    fi
  fi
  overlay=""
  if declare -f "dynamic_values_${key}" >/dev/null; then
    overlay=$("dynamic_values_${key}")
  fi

  # Explicit branches instead of an args array: bash 3.2 on macOS cannot
  # expand an empty array under set -u.
  info "Running helm upgrade --install ${release} (this can take a few minutes)..."
  # helm output goes to the log, never /dev/null: the one time it matters is
  # when the install fails, and that is exactly when it was being discarded.
  local helm_out="/tmp/homelab-helm-${key}.log"
  local rc=0 started
  started=$(date +%s)
  if [[ -n "$base" && -n "$overlay" ]]; then
    helm upgrade --install "$release" "$chart" --namespace "$ns" --version "$version" \
      --values "$base" --values "$overlay" --wait --timeout "$timeout" >"$helm_out" 2>&1 || rc=$?
  elif [[ -n "$base" ]]; then
    helm upgrade --install "$release" "$chart" --namespace "$ns" --version "$version" \
      --values "$base" --wait --timeout "$timeout" >"$helm_out" 2>&1 || rc=$?
  elif [[ -n "$overlay" ]]; then
    helm upgrade --install "$release" "$chart" --namespace "$ns" --version "$version" \
      --values "$overlay" --wait --timeout "$timeout" >"$helm_out" 2>&1 || rc=$?
  else
    helm upgrade --install "$release" "$chart" --namespace "$ns" --version "$version" \
      --wait --timeout "$timeout" >"$helm_out" 2>&1 || rc=$?
  fi
  # helm --wait can time out while the release still converges afterwards --
  # Jenkins' first run downloads every plugin and regularly overruns. Treat a
  # timeout as inconclusive and check the workloads before giving up, otherwise
  # post_install never runs and the component is left without its Ingress.
  if [[ $rc -ne 0 ]]; then
    local elapsed=$(( $(date +%s) - started ))
    [[ -n "${LOG_FILE:-}" ]] && cat "$helm_out" >> "$LOG_FILE" 2>/dev/null
    # A failure in seconds is a real error (a values conflict, a bad chart), not
    # a timeout. Only poll for late convergence when helm ran long enough that a
    # timeout is plausible -- otherwise the convergence check happily reports
    # success because the PREVIOUS release is still healthy.
    if [[ $elapsed -lt 60 ]]; then
      fail "${display} install failed after ${elapsed}s:"
      tail -5 "$helm_out" 2>/dev/null | sed 's/^/      /'
      log "${key} install FAILED after ${elapsed}s (see ${helm_out})"
      return 1
    fi
    warn "helm returned ${rc} for ${display} after ${elapsed}s (timeout ${timeout}) - checking whether it converged anyway"
    local waited=0
    while [[ $waited -lt 300 ]]; do
      if [[ "$(component_status "$key")" == "installed" ]] && \
         [[ -z "$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"')" ]] && \
         [[ -n "$(kubectl get pods -n "$ns" --no-headers 2>/dev/null)" ]]; then
        rc=0; break
      fi
      sleep 15
      waited=$((waited + 15))
    done
    if [[ $rc -ne 0 ]]; then
      fail "${display} install failed:"
      tail -5 "$helm_out" 2>/dev/null | sed 's/^/      /'
      log "${key} install FAILED (see ${helm_out})"
      return 1
    fi
    warn "${display} became healthy after the helm timeout - continuing"
    log "${key} converged after helm timeout"
  fi
  success "${display} installed"
  log "${key} installed"

  [[ -n "$overlay" ]] && rm -f "$overlay"
  if declare -f "post_install_${key}" >/dev/null; then "post_install_${key}"; fi
  return 0
}

# Scale every workload in the namespace to zero, remembering the replica count.
# Frees the memory exactly like uninstalling, but keeps PVCs, config and state.
suspend_component() {
  local key=$1 display ns obj reps
  display=$(component_field "$key" 2); ns=$(component_field "$key" 4)
  print_section "Suspending ${display}"
  log "Suspending ${key} (scaling ${ns} workloads to 0)"

  for obj in $(kubectl get deploy,statefulset -n "$ns" -o name 2>/dev/null); do
    reps=$(kubectl get "$obj" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [[ -z "$reps" || "$reps" == "0" ]] && continue
    kubectl annotate "$obj" -n "$ns" "${SUSPEND_ANNOTATION}=${reps}" --overwrite &>/dev/null
    kubectl scale "$obj" -n "$ns" --replicas=0 &>/dev/null && \
      success "${obj} scaled to 0 (was ${reps})"
  done
  success "${display} suspended - data and configuration kept"
  info "Resume from this menu; nothing was deleted."
}

resume_component() {
  local key=$1 display ns obj reps
  display=$(component_field "$key" 2); ns=$(component_field "$key" 4)
  print_section "Resuming ${display}"
  log "Resuming ${key}"

  for obj in $(kubectl get deploy,statefulset -n "$ns" -o name 2>/dev/null); do
    reps=$(kubectl get "$obj" -n "$ns" \
      -o jsonpath="{.metadata.annotations['${SUSPEND_ANNOTATION}']}" 2>/dev/null)
    [[ -z "$reps" ]] && reps=1
    kubectl scale "$obj" -n "$ns" --replicas="$reps" &>/dev/null && \
      success "${obj} scaled to ${reps}"
  done
  success "${display} resuming - give the pods a moment to become Ready"
}

uninstall_component() {
  local key=$1 display release ns app
  display=$(component_field "$key" 2); release=$(component_field "$key" 3)
  ns=$(component_field "$key" 4)

  print_section "Removing ${display}"
  if ! helm list -n "$ns" -q 2>/dev/null | grep -qx "$release"; then
    info "${display} is not installed (nothing to remove)"
    return 0
  fi

  # Argo CD Applications carry resources-finalizer.argocd.argoproj.io. Deleting
  # the namespace with those still set hangs it in Terminating forever, because
  # helm uninstall has already removed the controller that would clear them --
  # and a controller that is still alive would cascade-delete every workload the
  # Applications manage. Strip them first: removing Argo CD must never take the
  # deployed applications down with it.
  if [[ "$key" == "argocd" ]]; then
    for app in $(kubectl get applications -n "$ns" -o name 2>/dev/null); do
      kubectl patch "$app" -n "$ns" --type merge \
        -p '{"metadata":{"finalizers":null}}' &>/dev/null && \
        info "cleared finalizer on ${app} (its workloads keep running)"
    done
  fi

  helm uninstall "$release" --namespace "$ns" --wait &>/dev/null && \
    success "${display} uninstalled" || warn "Helm uninstall reported problems"
  kubectl delete namespace "$ns" --timeout=120s &>/dev/null || \
    warn "Namespace ${ns} did not delete cleanly - check for stuck finalizers"
  success "${display} removed"
  log "${key} removed"
}

# ─────────────────────────────────────────────
#  COMPONENT MENU
# ─────────────────────────────────────────────
manage_components() {
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    fail "Cluster '${CLUSTER_NAME}' is not running. Start it first."
    return 1
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null

  local key i sel action count
  while true; do
    print_section "Manage Components"
    echo ""
    i=1
    for key in $(component_keys); do
      printf "  ${CYAN}[%d]${NC} %-26s %b\n" "$i" "$(component_field "$key" 2)" "$(component_status_label "$key")"
      i=$((i + 1))
    done
    count=$((i - 1))
    echo ""
    echo -e "  ${CYAN}[b]${NC} Back to main menu"
    echo ""
    read -rp "  Select a component [1-${count}/b]: " sel
    [[ "$sel" == "b" || "$sel" == "B" ]] && return 0
    if ! echo "$sel" | grep -qE '^[0-9]+$' || [ "$sel" -lt 1 ] || [ "$sel" -gt "$count" ]; then
      warn "Invalid selection"; continue
    fi
    key=$(component_key_at "$sel")

    echo ""
    echo -e "  ${BOLD}$(component_field "$key" 2)${NC} is currently $(component_status_label "$key")"
    echo ""
    echo -e "  ${CYAN}[i]${NC} Install / upgrade"
    echo -e "  ${CYAN}[s]${NC} Suspend      (scale to 0 - frees memory, keeps all data)"
    echo -e "  ${CYAN}[r]${NC} Resume       (scale back up)"
    echo -e "  ${CYAN}[x]${NC} Remove       (helm uninstall + delete namespace)"
    echo -e "  ${CYAN}[c]${NC} Cancel"
    echo ""
    read -rp "  Action: " action
    case "$action" in
      i|I) install_component "$key"; print_hosts_reminder ;;
      s|S) suspend_component "$key" ;;
      r|R) resume_component "$key" ;;
      x|X)
        echo ""
        warn "This deletes the $(component_field "$key" 4) namespace and any PersistentVolumeClaims in it."
        warn "Suspend instead if you only want the memory back."
        read -rp "  Type 'remove' to confirm: " confirm
        [[ "$confirm" == "remove" ]] && uninstall_component "$key" || info "Cancelled"
        ;;
      *) info "Cancelled" ;;
    esac
    echo ""
    read -rp "  Press Enter to continue..." _
  done
}

# ─────────────────────────────────────────────
#  HOSTS FILE HELPER
# ─────────────────────────────────────────────
print_hosts_reminder() {
  print_section "/etc/hosts Entries Needed"
  echo -e "  Add these lines to ${BOLD}/etc/hosts${NC} if not already present:"
  echo ""
  echo -e "  ${YELLOW}sudo bash -c 'cat >> /etc/hosts << EOF"
  local _key _host
  for _key in $(component_keys); do
    for _host in $(component_hosts "$_key"); do
      echo "127.0.0.1  ${_host}"
    done
  done
  echo -e "EOF'${NC}"
  echo ""
}

# ─────────────────────────────────────────────
#  CLUSTER STATUS
# ─────────────────────────────────────────────
show_status() {
  print_section "Cluster Status"
  echo ""
  echo -e "  ${BOLD}Nodes:${NC}"
  kubectl get nodes -o wide 2>/dev/null || warn "Could not get nodes"
  echo ""
  echo -e "  ${BOLD}Resource usage (kubectl top nodes):${NC}"
  kubectl top nodes 2>/dev/null || warn "Metrics not available yet (metrics-server may still be starting)"
  echo ""
  echo -e "  ${BOLD}Resource usage (kubectl top pods -A):${NC}"
  kubectl top pods -A 2>/dev/null | head -50 || warn "Metrics not available yet (metrics-server may still be starting)"
  echo ""
  echo -e "  ${BOLD}Namespaces & Pods:${NC}"
  kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | grep -v "Completed" || true
  echo ""
  echo -e "  ${BOLD}Services (LoadBalancer):${NC}"
  kubectl get svc -A --field-selector=spec.type=LoadBalancer 2>/dev/null || true
}

# ─────────────────────────────────────────────
#  STOP / START CLUSTER (kind nodes are Docker containers)
# ─────────────────────────────────────────────
stop_cluster() {
  print_section "Stop Cluster"
  local containers
  containers=$(docker ps -a -q --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null)
  if [[ -z "$containers" ]]; then
    fail "Cluster '${CLUSTER_NAME}' does not exist. Run Setup first."
    return 1
  fi
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    local nodes
    nodes=$(kind get nodes --name "$CLUSTER_NAME" -q 2>/dev/null)
    if [[ -n "$nodes" ]]; then
      info "Stopping kind nodes: $nodes"
      for n in $nodes; do
        docker stop "$n" 2>/dev/null && success "Stopped $n" || warn "Failed to stop $n"
      done
    else
      docker stop $containers 2>/dev/null
      success "Stopped cluster containers"
    fi
  else
    local running
    running=$(docker ps -q --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null)
    if [[ -z "$running" ]]; then
      info "Cluster '${CLUSTER_NAME}' is already stopped."
      return 0
    fi
    info "Stopping cluster containers..."
    docker stop $running 2>/dev/null && success "Stopped cluster containers" || warn "Some containers may not have stopped"
  fi
  success "Cluster '${CLUSTER_NAME}' stopped (use Start cluster to resume)"
}

start_cluster() {
  print_section "Start Cluster"
  local containers
  containers=$(docker ps -a -q --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null)
  if [[ -z "$containers" ]]; then
    fail "Cluster '${CLUSTER_NAME}' does not exist. Run Setup first."
    return 1
  fi
  local running
  running=$(docker ps -q --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null)
  if [[ -n "$running" && "$(echo "$running" | wc -l)" -eq "$(echo "$containers" | wc -l)" ]]; then
    info "Cluster '${CLUSTER_NAME}' is already running."
    kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
    return 0
  fi
  info "Starting kind nodes..."
  for c in $containers; do
    docker start "$c" >/dev/null 2>&1 && success "Started $(docker inspect -f '{{.Name}}' "$c" | sed 's/^\///')" || warn "Failed to start $c"
  done
  info "Waiting for nodes to be Ready..."
  sleep 10
  kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
  kubectl wait --for=condition=Ready nodes --all --timeout=120s 2>/dev/null && \
    success "Cluster '${CLUSTER_NAME}' is running" || \
    warn "Nodes may still be starting; run 'Show cluster status' to check"
}

# ─────────────────────────────────────────────
#  TEARDOWN
# ─────────────────────────────────────────────
teardown_cluster() {
  print_section "Teardown"
  LOG_FILE="/tmp/homelab-$(date +%Y%m%d-%H%M%S).log"
  log "=== Teardown started ==="
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: This will delete the entire '${CLUSTER_NAME}' cluster!${NC}"
  echo -e "  All data (Jenkins jobs, ArgoCD apps, Grafana dashboards) will be lost."
  echo ""
  read -rp "  Are you sure? Type 'yes' to confirm: " confirm
  if [[ "$confirm" == "yes" ]]; then
    log "User confirmed teardown; deleting cluster"
    kind delete cluster --name "$CLUSTER_NAME" 2>&1 | tee -a "$LOG_FILE" && \
      success "Cluster '${CLUSTER_NAME}' deleted" || \
      warn "Cluster may not have existed"
    log "Cleaning up temp files"
    rm -f /tmp/kind-homelab.yaml /tmp/jenkins-values.yaml /tmp/prom-values.yaml
    rm -rf /tmp/kind-worker[0-9]*
    success "Cleanup complete"
    log "=== Teardown finished ==="
  else
    info "Teardown cancelled"
    log "Teardown cancelled by user"
  fi
}

# ─────────────────────────────────────────────
#  COMPONENT SELECTION MENU
# ─────────────────────────────────────────────
select_components() {
  echo ""
  echo -e "  ${BOLD}Select optional components to install:${NC}"
  echo ""
  local _key _i=1
  for _key in $(component_keys); do
    echo -e "  ${CYAN}[${_i}]${NC} $(component_field "$_key" 2)"
    _i=$((_i + 1))
  done
  echo -e "  ${CYAN}[a]${NC} All of the above"
  echo -e "  ${CYAN}[n]${NC} None (core only: MetalLB + Ingress + Metrics-Server)"
  echo ""
  read -rp "  Enter your choices (e.g. 1 3, or a): " choices

  SELECTED_COMPONENTS=""
  local _c _k
  for _c in $choices; do
    case "$_c" in
      a|A) SELECTED_COMPONENTS=$(component_keys | tr '\n' ' '); break ;;
      n|N) SELECTED_COMPONENTS=""; break ;;
      *)
        if echo "$_c" | grep -qE '^[0-9]+$'; then
          _k=$(component_key_at "$_c")
          if [[ -n "$_k" ]]; then
            SELECTED_COMPONENTS="${SELECTED_COMPONENTS}${_k} "
          else
            warn "Unknown option: $_c (skipping)"
          fi
        else
          warn "Unknown option: $_c (skipping)"
        fi
        ;;
    esac
  done
}

# ─────────────────────────────────────────────
#  SETUP CLUSTER
# ─────────────────────────────────────────────
setup_cluster() {
  local _k
  check_dependencies

  LOG_FILE="/tmp/homelab-$(date +%Y%m%d-%H%M%S).log"
  log "=== Setup cluster started ==="
  echo -e "  ${BOLD}Log file: ${CYAN}${LOG_FILE}${NC}"
  echo ""

  print_section "Creating kind Cluster: ${CLUSTER_NAME}"

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' already exists."
    log "Cluster already exists; prompting for choice"
    echo ""
    echo -e "  ${CYAN}[1]${NC} Use existing cluster"
    echo -e "  ${CYAN}[2]${NC} Delete and recreate"
    echo ""
    read -rp "  Choice [1/2]: " cluster_choice
    if [[ "$cluster_choice" == "2" ]]; then
      kind delete cluster --name "$CLUSTER_NAME" &>/dev/null
      info "Existing cluster deleted, creating fresh..."
      log "Cluster deleted; creating fresh cluster"
      create_kind_config
      kind create cluster --config /tmp/kind-homelab.yaml --image "kindest/node:${K8S_VERSION}" 2>&1 | tee -a "$LOG_FILE" && \
        success "Cluster '${CLUSTER_NAME}' created"
      [[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
      log "Kind cluster created successfully"
    else
      info "Using existing cluster"
      log "Using existing cluster (no create)"
      kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
    fi
  else
    create_kind_config
    info "Creating kind cluster (1 control-plane + ${WORKER_COUNT} worker(s))..."
    log "Creating kind cluster with config /tmp/kind-homelab.yaml"
    kind create cluster --config /tmp/kind-homelab.yaml --image "kindest/node:${K8S_VERSION}" 2>&1 | tee -a "$LOG_FILE" && \
      success "Cluster '${CLUSTER_NAME}' created"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || exit 1
    log "Kind cluster created successfully"
  fi

  kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
  success "kubectl context set to kind-${CLUSTER_NAME}"
  log "kubectl context set to kind-${CLUSTER_NAME}"

  # Wait for cluster to be ready before installing core components
  info "Waiting for cluster nodes to be Ready..."
  log "Waiting for all nodes to be Ready (timeout 120s)"
  kubectl wait --for=condition=Ready nodes --all --timeout=120s 2>/dev/null && \
    success "Cluster nodes ready" || \
    warn "Nodes may still be starting; continuing anyway..."
  log "Node wait completed"

  # Install core components
  log "Installing core components: MetalLB, Ingress-Nginx, Metrics-Server"
  install_metallb
  install_ingress_nginx
  install_metrics_server
  log "Core components installed"

  # Component selection
  log "Prompting for optional components"
  select_components

  # Install selected components
  log "Installing optional components: ${SELECTED_COMPONENTS:-none}"
  for _k in $SELECTED_COMPONENTS; do
    install_component "$_k" || warn "$(component_field "$_k" 2) failed - continuing"
  done

  # Summary
  log "=== Setup cluster finished ==="
  print_section "✅  Setup Complete!"
  echo ""
  success "Cluster '${CLUSTER_NAME}' is ready"
  echo ""
  echo -e "  ${BOLD}Installed components:${NC}"
  echo -e "  ${OK} MetalLB"
  echo -e "  ${OK} Ingress-Nginx"
  echo -e "  ${OK} Metrics-Server"
  for _k in $SELECTED_COMPONENTS; do
    echo -e "  ${OK} $(component_field "$_k" 2)"
  done

  print_hosts_reminder
}

# ─────────────────────────────────────────────
#  ADD COMPONENTS TO EXISTING CLUSTER
# ─────────────────────────────────────────────
add_components() {
  local _k
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    fail "Cluster '${CLUSTER_NAME}' does not exist. Run Setup first."
    return 1
  fi

  LOG_FILE="/tmp/homelab-$(date +%Y%m%d-%H%M%S).log"
  log "=== Add components started ==="
  echo -e "  ${BOLD}Log file: ${CYAN}${LOG_FILE}${NC}"
  echo ""

  kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
  log "kubectl context set to kind-${CLUSTER_NAME}"

  # Ensure core stack (MetalLB + Ingress-Nginx + Metrics-Server) is installed
  log "Ensuring core stack: MetalLB, Ingress-Nginx, Metrics-Server"
  install_metallb
  install_ingress_nginx
  install_metrics_server
  log "Core stack ensured"

  log "Prompting for optional components"
  select_components

  log "Installing optional components: ${SELECTED_COMPONENTS:-none}"
  for _k in $SELECTED_COMPONENTS; do
    install_component "$_k" || warn "$(component_field "$_k" 2) failed - continuing"
  done

  log "=== Add components finished ==="
  print_section "Done"
  echo -e "  ${OK} MetalLB"
  echo -e "  ${OK} Ingress-Nginx"
  echo -e "  ${OK} Metrics-Server"
  for _k in $SELECTED_COMPONENTS; do
    echo -e "  ${OK} $(component_field "$_k" 2)"
  done

  print_hosts_reminder
}

# ─────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────
main_menu() {
  print_banner

  # Show cluster status in menu
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "  Cluster Status: ${GREEN}${BOLD}RUNNING${NC} (${CLUSTER_NAME})"
  else
    local stopped_containers
    stopped_containers=$(docker ps -a -q --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null)
    if [[ -n "$stopped_containers" ]]; then
      echo -e "  Cluster Status: ${YELLOW}${BOLD}STOPPED${NC} (${CLUSTER_NAME})"
    else
      echo -e "  Cluster Status: ${RED}${BOLD}NOT RUNNING${NC}"
    fi
  fi

  echo ""
  echo -e "  ${BOLD}What would you like to do?${NC}"
  echo ""
  echo -e "  ${CYAN}[1]${NC} 🚀  Setup new cluster + choose components"
  echo -e "  ${CYAN}[2]${NC} ➕  Add components to existing cluster"
  echo -e "  ${CYAN}[3]${NC} 📊  Show cluster status"
  echo -e "  ${CYAN}[4]${NC} ⏹   Stop cluster"
  echo -e "  ${CYAN}[5]${NC} ▶   Start cluster"
  echo -e "  ${CYAN}[6]${NC} 🔧  Manage components (install / suspend / resume / remove)"
  echo -e "  ${CYAN}[7]${NC} 💣  Teardown / delete cluster"
  echo -e "  ${CYAN}[8]${NC} 🚪  Exit"
  echo ""
  read -rp "  Enter choice [1-8]: " choice

  case $choice in
    1) setup_cluster ;;
    2) add_components ;;
    3) show_status ;;
    4) stop_cluster ;;
    5) start_cluster ;;
    6) manage_components ;;
    7) teardown_cluster ;;
    8) echo ""; info "Goodbye!"; echo ""; exit 0 ;;
    *) warn "Invalid option. Please run the script again."; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────
main_menu