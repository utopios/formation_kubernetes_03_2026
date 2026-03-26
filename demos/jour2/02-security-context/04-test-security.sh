#!/usr/bin/env bash
# =============================================================================
# 04-test-security.sh — Démonstration comparative sécurité
#
# Compare le comportement d'un pod non sécurisé vs sécurisé
# =============================================================================
set -euo pipefail

export KUBECONFIG=/tmp/kind-kubeconfig

echo "======================================================"
echo " Démo Security Context — Comparaison insecure vs secure"
echo "======================================================"

echo ""
echo "[INFO] Déploiement des pods..."
kubectl apply -f "$(dirname "$0")/01-insecure-pod.yaml"
kubectl apply -f "$(dirname "$0")/02-secure-pod.yaml"
kubectl apply -f "$(dirname "$0")/03-pod-security-standards.yaml"

echo "[INFO] Attente des pods..."
kubectl wait --for=condition=Ready pod/insecure-pod --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod/secure-pod --timeout=60s 2>/dev/null || true

echo ""
echo "======================================================"
echo " TEST 1 : Identité du processus"
echo "======================================================"
echo ""
echo "--- insecure-pod : qui suis-je ? ---"
kubectl exec insecure-pod -- id
kubectl exec insecure-pod -- whoami

echo ""
echo "--- secure-pod : qui suis-je ? ---"
kubectl exec secure-pod -- id 2>&1 || true
kubectl exec secure-pod -- whoami 2>&1 || true

echo ""
echo "======================================================"
echo " TEST 2 : Écriture sur le filesystem"
echo "======================================================"

echo ""
echo "--- insecure-pod : écriture sur / (attendu: OK) ---"
kubectl exec insecure-pod -- sh -c "touch /test-write && echo 'Écriture OK sur /' && rm /test-write"

echo ""
echo "--- secure-pod : écriture sur / (attendu: REFUSÉ) ---"
kubectl exec secure-pod -- sh -c "touch /test-write" 2>&1 || echo "[OK] Read-only filesystem — écriture bloquée"

echo ""
echo "--- secure-pod : écriture sur /tmp (attendu: OK — tmpfs) ---"
kubectl exec secure-pod -- sh -c "touch /tmp/test-write && echo 'Écriture OK sur /tmp' && rm /tmp/test-write"

echo ""
echo "======================================================"
echo " TEST 3 : Linux Capabilities"
echo "======================================================"

echo ""
echo "--- insecure-pod : capabilities actives ---"
kubectl exec insecure-pod -- sh -c "cat /proc/1/status | grep Cap" 2>/dev/null || true

echo ""
echo "--- secure-pod : capabilities (attendu: tout à 0) ---"
kubectl exec secure-pod -- sh -c "cat /proc/1/status | grep Cap" 2>/dev/null || true
echo "(CapEff=0000000000000000 = zéro capability)"

echo ""
echo "======================================================"
echo " TEST 4 : Pod Security Standards"
echo "======================================================"
kubectl get pod restricted-compliant -n ns-restricted 2>/dev/null \
  && echo "[OK] Pod compliant déployé dans ns-restricted" \
  || echo "[INFO] Pod non déployé"

echo ""
echo "--- Test refus d'un pod non conforme dans ns-restricted ---"
kubectl apply -f - 2>&1 <<'EOF' || echo "[OK] Pod refusé par Pod Security Standards"
apiVersion: v1
kind: Pod
metadata:
  name: will-be-rejected
  namespace: ns-restricted
spec:
  containers:
    - name: app
      image: alpine:3.19
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi
EOF

echo ""
echo "======================================================"
echo " ✓ Démo Security Context terminée"
echo "======================================================"
