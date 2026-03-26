#!/usr/bin/env bash
# Pod Security Standards — passage progressif warn → enforce
set -euo pipefail

NAMESPACE="voting"

echo "=== Étape 1 : mode WARN (observe sans bloquer) ==="
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  --overwrite

echo "Restart des deployments pour voir les avertissements PSS..."
kubectl rollout restart deployment -n "${NAMESPACE}"
kubectl rollout status deployment -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== Étape 2 : mode ENFORCE (bloque les pods non-conformes) ==="
echo "Appliquer les Deployments sécurisés avant d'activer enforce !"
read -r -p "Tous les pods sont-ils conformes ? (o/N) " CONFIRM
if [[ "${CONFIRM,,}" != "o" ]]; then
  echo "Abandon. Appliquez d'abord vote-secured.yaml, worker-secured.yaml, result-secured.yaml."
  exit 1
fi

kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

echo "=== Vérification ==="
kubectl get namespace "${NAMESPACE}" \
  --show-labels | tr ',' '\n' | grep pod-security

echo ""
echo "Test de rejet d'un pod root (doit être refusé) :"
kubectl run test-root --image=nginx --restart=Never -n "${NAMESPACE}" --dry-run=server 2>&1 || true
