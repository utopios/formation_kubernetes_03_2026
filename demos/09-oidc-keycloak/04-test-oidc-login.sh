#!/usr/bin/env bash
# =============================================================================
# 04-test-oidc-login.sh — Test end-to-end OIDC : login Keycloak → kubectl
# Usage : bash 04-test-oidc-login.sh
# =============================================================================
set -euo pipefail

export KUBECONFIG="/tmp/oidc-kubeconfig"
KEYCLOAK_URL="https://localhost:30443"
REALM="k8s"
CLIENT_ID="kubernetes"

echo "======================================================"
echo " Test OIDC end-to-end — Keycloak → Kubernetes"
echo "======================================================"

# ==========================================================================
# ÉTAPE 1 : Obtenir un token OIDC depuis Keycloak (Resource Owner Password Flow)
# ==========================================================================
echo ""
echo "=== ÉTAPE 1 : Login alice via Keycloak ==="
ALICE_RESPONSE=$(curl -sf -k \
  -d "client_id=${CLIENT_ID}" \
  -d "username=alice" \
  -d "password=alice123" \
  -d "grant_type=password" \
  -d "scope=openid email" \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token")

ALICE_TOKEN=$(echo "${ALICE_RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id_token'])")
echo "[OK] Token OIDC obtenu pour alice (${#ALICE_TOKEN} chars)"

# ==========================================================================
# ÉTAPE 2 : Décoder le JWT (afficher les claims)
# ==========================================================================
echo ""
echo "=== ÉTAPE 2 : Contenu du JWT id_token ==="
PAYLOAD=$(echo "${ALICE_TOKEN}" | cut -d'.' -f2)
PAD=$((4 - ${#PAYLOAD} % 4))
[ $PAD -ne 4 ] && PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PAD))"
echo "${PAYLOAD}" | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null | grep -E '"email"|"groups"|"iss"|"preferred_username"' || \
  echo "${PAYLOAD}" | base64 -d 2>/dev/null

# ==========================================================================
# ÉTAPE 3 : Configurer kubectl avec le token OIDC
# ==========================================================================
echo ""
echo "=== ÉTAPE 3 : Configuration kubectl pour alice (OIDC) ==="
kubectl config set-credentials alice-oidc \
  --token="${ALICE_TOKEN}"

kubectl config set-context alice-oidc-ctx \
  --cluster="k3d-formation-oidc" \
  --user="alice-oidc" \
  --namespace="dev"

echo "[OK] Contexte alice-oidc-ctx créé"

# ==========================================================================
# ÉTAPE 4 : Tester les droits RBAC avec le token OIDC
# ==========================================================================
echo ""
echo "=== ÉTAPE 4 : Tests RBAC alice (OIDC) ==="

echo ""
echo "--- get pods dans dev (attendu: OK via RoleBinding) ---"
kubectl --context=alice-oidc-ctx get pods -n dev 2>&1 || true

echo ""
echo "--- delete pods dans dev (attendu: Forbidden) ---"
kubectl --context=alice-oidc-ctx delete pod test-inexistant -n dev 2>&1 || true

echo ""
echo "--- get nodes (attendu: OK via ClusterRoleBinding groupe dev-team) ---"
kubectl --context=alice-oidc-ctx get nodes 2>&1 || true

echo ""
echo "--- get secrets dans dev (attendu: Forbidden) ---"
kubectl --context=alice-oidc-ctx get secrets -n dev 2>&1 || true

# ==========================================================================
# ÉTAPE 5 : Même test avec bob (pas dans dev-team, aucun RBAC)
# ==========================================================================
echo ""
echo "=== ÉTAPE 5 : Login bob (aucun RBAC) ==="
BOB_RESPONSE=$(curl -sf -k \
  -d "client_id=${CLIENT_ID}" \
  -d "username=bob" \
  -d "password=bob123" \
  -d "grant_type=password" \
  -d "scope=openid email" \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token")

BOB_TOKEN=$(echo "${BOB_RESPONSE}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id_token'])")

kubectl config set-credentials bob-oidc --token="${BOB_TOKEN}"
kubectl config set-context bob-oidc-ctx \
  --cluster="k3d-formation-oidc" \
  --user="bob-oidc" \
  --namespace="dev"

echo ""
echo "--- get pods avec bob (attendu: Forbidden — aucun RBAC) ---"
kubectl --context=bob-oidc-ctx get pods -n dev 2>&1 || true

echo ""
echo "======================================================"
echo " Résumé"
echo "======================================================"
echo "  alice@formation.local (groupe: dev-team) :"
echo "    ✓ get pods/services/deployments dans dev  (RoleBinding oidc-alice-dev-reader)"
echo "    ✓ get nodes/namespaces                    (ClusterRoleBinding oidc-devteam-cluster-reader)"
echo "    ✗ delete pods                             (Forbidden)"
echo "    ✗ get secrets                             (Forbidden)"
echo ""
echo "  bob@formation.local :"
echo "    ✗ tout                                    (aucun RBAC)"
