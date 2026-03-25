#!/usr/bin/env bash
# =============================================================================
# 00-setup-kind.sh — Cluster Kind pour les démos Jour 1
# Usage    : bash 00-setup-kind.sh
# Prérequis : Docker en cours d'exécution, kind, kubectl installés
# =============================================================================
set -euo pipefail

CLUSTER_NAME="formation-k8s"

echo "======================================================"
echo " Setup cluster Kind — Formation Kubernetes Jour 1"
echo "======================================================"

# Supprimer si déjà existant
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[INFO] Suppression du cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

# Créer le cluster multi-nœuds avec port-mappings pour les démos NodePort
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30090
        hostPort: 30090
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
EOF

echo "[INFO] Labels sur les workers..."
kubectl label node "${CLUSTER_NAME}-worker"  env=dev        --overwrite
kubectl label node "${CLUSTER_NAME}-worker2" env=staging    --overwrite
kubectl label node "${CLUSTER_NAME}-worker3" env=production --overwrite

echo "[INFO] Création des namespaces..."
kubectl apply -f 01-namespaces.yaml

echo "[INFO] Installation Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

echo ""
echo "======================================================"
echo " Cluster prêt !"
echo "======================================================"
kubectl get nodes -o wide
echo ""
