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
JENKINS_HELM_VERSION="5.1.25"
PROM_STACK_HELM_VERSION="59.1.0"

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
#  OPTIONAL: ARGOCD
# ─────────────────────────────────────────────
install_argocd() {
  print_section "Installing ArgoCD"

  helm repo add argo https://argoproj.github.io/argo-helm --force-update &>/dev/null
  helm repo update &>/dev/null
  ensure_namespace "$NS_ARGOCD"

  helm upgrade --install argocd argo/argo-cd \
    --namespace "$NS_ARGOCD" \
    --version "$ARGOCD_HELM_VERSION" \
    --set server.service.type=ClusterIP \
    --set configs.params."server\.insecure"=true \
    --wait \
    --timeout 5m \
    &>/dev/null && success "ArgoCD installed"

  # Create Ingress for ArgoCD
  kubectl apply -f - <<EOF &>/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: ${NS_ARGOCD}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

  wait_for_pods "$NS_ARGOCD" "app.kubernetes.io/name=argocd-server" 180

  local argocd_pass
  argocd_pass=$(kubectl -n "$NS_ARGOCD" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")

  success "ArgoCD ready"
  echo ""
  echo -e "    ${BOLD}ArgoCD Credentials:${NC}"
  echo -e "    URL      : ${YELLOW}http://argocd.local${NC}"
  echo -e "    Username : ${YELLOW}admin${NC}"
  echo -e "    Password : ${YELLOW}${argocd_pass}${NC}"
}

# ─────────────────────────────────────────────
#  OPTIONAL: JENKINS
# ─────────────────────────────────────────────
install_jenkins() {
  print_section "Installing Jenkins"

  helm repo add jenkins https://charts.jenkins.io --force-update &>/dev/null
  helm repo update &>/dev/null
  ensure_namespace "$NS_JENKINS"

  cat <<EOF > /tmp/jenkins-values.yaml
controller:
  adminUser: admin
  adminPassword: homelab123
  serviceType: ClusterIP
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1500m"
      memory: "2Gi"
  javaOpts: "-Xms512m -Xmx1024m"
  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - blueocean:latest
    - docker-workflow:latest
persistence:
  enabled: true
  size: 5Gi
agent:
  enabled: true
  resources:
    requests:
      cpu: "200m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
EOF

  helm upgrade --install jenkins jenkins/jenkins \
    --namespace "$NS_JENKINS" \
    --version "$JENKINS_HELM_VERSION" \
    --values /tmp/jenkins-values.yaml \
    --wait \
    --timeout 8m \
    &>/dev/null && success "Jenkins installed"

  # Create Ingress for Jenkins
  kubectl apply -f - <<EOF &>/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins-ingress
  namespace: ${NS_JENKINS}
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
spec:
  ingressClassName: nginx
  rules:
    - host: jenkins.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jenkins
                port:
                  number: 8080
EOF

  wait_for_pods "$NS_JENKINS" "app.kubernetes.io/component=jenkins-controller" 300

  success "Jenkins ready"
  echo ""
  echo -e "    ${BOLD}Jenkins Credentials:${NC}"
  echo -e "    URL      : ${YELLOW}http://jenkins.local${NC}"
  echo -e "    Username : ${YELLOW}admin${NC}"
  echo -e "    Password : ${YELLOW}homelab123${NC}"
}

# ─────────────────────────────────────────────
#  OPTIONAL: PROMETHEUS + GRAFANA
# ─────────────────────────────────────────────
install_monitoring() {
  print_section "Installing Prometheus + Grafana"

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update &>/dev/null
  helm repo update &>/dev/null
  ensure_namespace "$NS_MONITORING"

  cat <<EOF > /tmp/prom-values.yaml
grafana:
  adminPassword: homelab123
  service:
    type: ClusterIP
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - grafana.local
    paths:
      - /
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "500m"

prometheus:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
    hosts:
      - prometheus.local
    paths:
      - /
  prometheusSpec:
    resources:
      requests:
        memory: "512Mi"
        cpu: "200m"
      limits:
        memory: "1Gi"
        cpu: "500m"
    retention: 3d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi

alertmanager:
  enabled: false

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
EOF

  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace "$NS_MONITORING" \
    --version "$PROM_STACK_HELM_VERSION" \
    --values /tmp/prom-values.yaml \
    --wait \
    --timeout 8m \
    &>/dev/null && success "Prometheus + Grafana installed"

  wait_for_pods "$NS_MONITORING" "app.kubernetes.io/name=grafana" 180

  success "Grafana ready"
  echo ""
  echo -e "    ${BOLD}Grafana Credentials:${NC}"
  echo -e "    URL      : ${YELLOW}http://grafana.local${NC}"
  echo -e "    Username : ${YELLOW}admin${NC}"
  echo -e "    Password : ${YELLOW}homelab123${NC}"
  echo ""
  echo -e "    ${BOLD}Prometheus:${NC}"
  echo -e "    URL      : ${YELLOW}http://prometheus.local${NC}"
}

# ─────────────────────────────────────────────
#  UNINSTALL OPTIONAL COMPONENTS
# ─────────────────────────────────────────────
uninstall_argocd() {
  print_section "Uninstalling ArgoCD"
  if helm list -n "$NS_ARGOCD" -q 2>/dev/null | grep -qx "argocd"; then
    helm uninstall argocd --namespace "$NS_ARGOCD" --wait 2>/dev/null && \
      success "ArgoCD uninstalled" || warn "Helm uninstall had issues"
    kubectl delete namespace "$NS_ARGOCD" --timeout=60s 2>/dev/null || true
  else
    info "ArgoCD is not installed (nothing to uninstall)"
  fi
}

uninstall_jenkins() {
  print_section "Uninstalling Jenkins"
  if helm list -n "$NS_JENKINS" -q 2>/dev/null | grep -qx "jenkins"; then
    helm uninstall jenkins --namespace "$NS_JENKINS" --wait 2>/dev/null && \
      success "Jenkins uninstalled" || warn "Helm uninstall had issues"
    kubectl delete namespace "$NS_JENKINS" --timeout=120s 2>/dev/null || true
  else
    info "Jenkins is not installed (nothing to uninstall)"
  fi
}

uninstall_monitoring() {
  print_section "Uninstalling Prometheus + Grafana"
  if helm list -n "$NS_MONITORING" -q 2>/dev/null | grep -qx "kube-prometheus-stack"; then
    helm uninstall kube-prometheus-stack --namespace "$NS_MONITORING" --wait 2>/dev/null && \
      success "Prometheus + Grafana uninstalled" || warn "Helm uninstall had issues"
    kubectl delete namespace "$NS_MONITORING" --timeout=120s 2>/dev/null || true
  else
    info "Prometheus + Grafana is not installed (nothing to uninstall)"
  fi
}

select_components_to_uninstall() {
  echo ""
  echo -e "  ${BOLD}Select optional components to uninstall:${NC}"
  echo ""
  echo -e "  ${CYAN}[1]${NC} ArgoCD"
  echo -e "  ${CYAN}[2]${NC} Jenkins"
  echo -e "  ${CYAN}[3]${NC} Prometheus + Grafana (Monitoring)"
  echo -e "  ${CYAN}[4]${NC} All of the above"
  echo -e "  ${CYAN}[5]${NC} Cancel"
  echo ""
  read -rp "  Enter your choices (e.g. 1 2 or 4): " choices

  if echo " $choices " | grep -q ' 5 '; then
    info "Uninstall cancelled."
    return 1
  fi

  UNINSTALL_ARGOCD=false
  UNINSTALL_JENKINS=false
  UNINSTALL_MONITORING=false

  for choice in $choices; do
    case $choice in
      1) UNINSTALL_ARGOCD=true ;;
      2) UNINSTALL_JENKINS=true ;;
      3) UNINSTALL_MONITORING=true ;;
      4) UNINSTALL_ARGOCD=true; UNINSTALL_JENKINS=true; UNINSTALL_MONITORING=true ;;
      *) warn "Unknown option: $choice (skipping)" ;;
    esac
  done
  return 0
}

uninstall_components() {
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    fail "Cluster '${CLUSTER_NAME}' does not exist or is stopped. Start the cluster first."
    return 1
  fi

  kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null

  print_section "Uninstall Optional Components"
  echo -e "  ${WARN} This will remove the selected components and their data (e.g. Jenkins jobs, Grafana dashboards).${NC}"
  echo ""

  select_components_to_uninstall || return 0

  $UNINSTALL_ARGOCD    && uninstall_argocd
  $UNINSTALL_JENKINS   && uninstall_jenkins
  $UNINSTALL_MONITORING && uninstall_monitoring

  print_section "Uninstall complete"
  success "Selected components have been uninstalled."
}

# ─────────────────────────────────────────────
#  HOSTS FILE HELPER
# ─────────────────────────────────────────────
print_hosts_reminder() {
  print_section "/etc/hosts Entries Needed"
  echo -e "  Add these lines to ${BOLD}/etc/hosts${NC} if not already present:"
  echo ""
  echo -e "  ${YELLOW}sudo bash -c 'cat >> /etc/hosts << EOF"
  echo "127.0.0.1  argocd.local"
  echo "127.0.0.1  jenkins.local"
  echo "127.0.0.1  grafana.local"
  echo "127.0.0.1  prometheus.local"
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
  echo -e "  ${CYAN}[1]${NC} ArgoCD           (GitOps CD)"
  echo -e "  ${CYAN}[2]${NC} Jenkins          (CI pipelines)"
  echo -e "  ${CYAN}[3]${NC} Prometheus + Grafana (Monitoring)"
  echo -e "  ${CYAN}[4]${NC} All of the above"
  echo -e "  ${CYAN}[5]${NC} None (core only: MetalLB + Ingress + Metrics-Server)"
  echo ""
  read -rp "  Enter your choices (e.g. 1 2 or 4): " choices

  INSTALL_ARGOCD=false
  INSTALL_JENKINS=false
  INSTALL_MONITORING=false

  for choice in $choices; do
    case $choice in
      1) INSTALL_ARGOCD=true ;;
      2) INSTALL_JENKINS=true ;;
      3) INSTALL_MONITORING=true ;;
      4) INSTALL_ARGOCD=true; INSTALL_JENKINS=true; INSTALL_MONITORING=true ;;
      5) ;;
      *) warn "Unknown option: $choice (skipping)" ;;
    esac
  done
}

# ─────────────────────────────────────────────
#  SETUP CLUSTER
# ─────────────────────────────────────────────
setup_cluster() {
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
  log "Installing optional components (ArgoCD=$INSTALL_ARGOCD Jenkins=$INSTALL_JENKINS Monitoring=$INSTALL_MONITORING)"
  $INSTALL_ARGOCD    && install_argocd
  $INSTALL_JENKINS   && install_jenkins
  $INSTALL_MONITORING && install_monitoring

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
  $INSTALL_ARGOCD    && echo -e "  ${OK} ArgoCD     → http://argocd.local"
  $INSTALL_JENKINS   && echo -e "  ${OK} Jenkins    → http://jenkins.local"
  $INSTALL_MONITORING && echo -e "  ${OK} Grafana    → http://grafana.local"
  $INSTALL_MONITORING && echo -e "  ${OK} Prometheus → http://prometheus.local"

  print_hosts_reminder
}

# ─────────────────────────────────────────────
#  ADD COMPONENTS TO EXISTING CLUSTER
# ─────────────────────────────────────────────
add_components() {
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

  log "Installing optional components (ArgoCD=$INSTALL_ARGOCD Jenkins=$INSTALL_JENKINS Monitoring=$INSTALL_MONITORING)"
  $INSTALL_ARGOCD    && install_argocd
  $INSTALL_JENKINS   && install_jenkins
  $INSTALL_MONITORING && install_monitoring

  log "=== Add components finished ==="
  print_section "Done"
  echo -e "  ${OK} MetalLB"
  echo -e "  ${OK} Ingress-Nginx"
  echo -e "  ${OK} Metrics-Server"
  $INSTALL_ARGOCD    && echo -e "  ${OK} ArgoCD     → http://argocd.local"
  $INSTALL_JENKINS   && echo -e "  ${OK} Jenkins    → http://jenkins.local"
  $INSTALL_MONITORING && echo -e "  ${OK} Grafana    → http://grafana.local"
  $INSTALL_MONITORING && echo -e "  ${OK} Prometheus → http://prometheus.local"

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
  echo -e "  ${CYAN}[6]${NC} ➖  Uninstall optional components"
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
    6) uninstall_components ;;
    7) teardown_cluster ;;
    8) echo ""; info "Goodbye!"; echo ""; exit 0 ;;
    *) warn "Invalid option. Please run the script again."; exit 1 ;;
  esac
}

# ─────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────
main_menu