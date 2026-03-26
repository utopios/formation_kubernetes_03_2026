#!/usr/bin/env bash
# =============================================================================
# bootstrap-cluster.sh
# Crée un cluster kind avec Calico (CNI) et metrics-server installés
# Usage: bash bootstrap-cluster.sh [nom-du-cluster]
# =============================================================================
set -euo pipefail

CLUSTER_NAME="${1:-voting-lab}"
CALICO_VERSION="v3.27.3"
METRICS_SERVER_VERSION="v0.7.1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
check_ok(){ echo -e "${GREEN}[OK]${NC}   $*"; }

# ---------------------------------------------------------------------------
# 1. Pré-requis
# ---------------------------------------------------------------------------
info "Vérification des pré-requis..."
for cmd in kind kubectl docker; do
  command -v "$cmd" &>/dev/null || error "$cmd n'est pas installé. Installez-le d'abord."
  check_ok "$cmd trouvé : $(command -v $cmd)"
done

docker info &>/dev/null || error "Docker ne tourne pas. Démarrez Docker Desktop."
check_ok "Docker est actif."

# ---------------------------------------------------------------------------
# 2. Création du cluster kind (NetworkPolicy support = disableDefaultCNI)
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Le cluster '${CLUSTER_NAME}' existe déjà. On le supprime pour repartir propre."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

info "Création du cluster kind '${CLUSTER_NAME}' (CNI désactivé pour Calico)..."
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  # Désactiver le CNI par défaut pour installer Calico
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"   # plage par défaut de Calico
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF

check_ok "Cluster kind créé."

# Cibler le bon contexte kubectl
kubectl config use-context "kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 3. Installation de Calico
# ---------------------------------------------------------------------------
info "Installation de Calico ${CALICO_VERSION}..."
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

info "Attente que les pods Calico soient Running (max 3 min)..."
kubectl wait --namespace kube-system \
  --for=condition=Ready pod \
  --selector=k8s-app=calico-node \
  --timeout=180s

kubectl wait --namespace kube-system \
  --for=condition=Ready pod \
  --selector=k8s-app=calico-kube-controllers \
  --timeout=120s

check_ok "Calico est opérationnel."

# Vérification : les NetworkPolicies sont bien supportées
info "Vérification du support NetworkPolicy..."
kubectl api-resources | grep -q "networkpolicies" \
  && check_ok "NetworkPolicy API disponible." \
  || error "NetworkPolicy API non disponible — Calico n'est pas bien installé."

# ---------------------------------------------------------------------------
# 4. Installation de metrics-server (avec patch pour kind/TLS)
# ---------------------------------------------------------------------------
info "Installation de metrics-server ${METRICS_SERVER_VERSION}..."

kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

# kind utilise des certificats auto-signés → patch pour désactiver la vérif TLS
kubectl patch deployment metrics-server \
  --namespace kube-system \
  --type='json' \
  --patch='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    }
  ]'

info "Attente que metrics-server soit Ready (max 2 min)..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

check_ok "metrics-server est opérationnel."

# ---------------------------------------------------------------------------
# 5. Attente que tous les nœuds soient Ready
# ---------------------------------------------------------------------------
info "Attente que tous les nœuds soient Ready..."
kubectl wait nodes --all --for=condition=Ready --timeout=180s
check_ok "Tous les nœuds sont Ready."

# ---------------------------------------------------------------------------
# 6. Récapitulatif
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
info "Cluster '${CLUSTER_NAME}' prêt !"
echo ""
kubectl get nodes -o wide
echo ""
info "Pods système :"
kubectl get pods -n kube-system --no-headers | awk '{printf "  %-45s %s\n", $1, $3}'
echo ""
info "Test metrics (peut prendre 30s supplémentaires) :"
echo "  kubectl top nodes"
echo "  kubectl top pods -A"
echo ""
info "Prochaine étape :"
echo "  kubectl create namespace voting"
echo "  kubectl apply -f ../01-network-policies/"
echo "========================================================"
