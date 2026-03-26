#!/usr/bin/env bash
# Génère de la charge HTTP vers vote pour déclencher le HPA
set -euo pipefail

NAMESPACE="voting"
VOTE_SVC="vote"
VOTE_PORT="5000"

echo "=== Surveillance HPA (ctrl+C pour arrêter) ==="
echo "Dans un autre terminal, lancez :"
echo "  kubectl get hpa vote -n ${NAMESPACE} -w"
echo ""

echo "Démarrage du générateur de charge..."
kubectl run load-generator \
  --image=busybox \
  --restart=Never \
  --namespace="${NAMESPACE}" \
  -- /bin/sh -c "while true; do wget -q -O- http://${VOTE_SVC}:${VOTE_PORT}/ > /dev/null 2>&1; done"

echo "Générateur lancé. Pour l'arrêter :"
echo "  kubectl delete pod load-generator -n ${NAMESPACE}"
echo ""
echo "Observations attendues :"
echo "  - Le HPA commencera à scaler ~30-60s après que CPU > 60%"
echo "  - Après suppression du générateur, le scale-down prendra ~5 min (stabilizationWindowSeconds: 300)"
