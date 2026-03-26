#!/usr/bin/env bash
# =============================================================================
# 02-configure-keycloak.sh — Configurer Keycloak via son API REST
# Crée : realm "k8s", client "kubernetes", groupes, utilisateurs alice et bob
# Usage : bash 02-configure-keycloak.sh
# =============================================================================
set -euo pipefail

KEYCLOAK_URL="http://localhost:31080"   # HTTP pour l'admin API (k3d port-forward 31080→30080)
ADMIN_USER="admin"
ADMIN_PASS="admin123"
REALM="k8s"

echo "======================================================"
echo " Configuration Keycloak pour OIDC Kubernetes"
echo "======================================================"

# Attendre que Keycloak soit disponible
echo "[INFO] Attente de Keycloak..."
until curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; do
  echo "  Keycloak pas encore prêt, retry dans 5s..."
  sleep 5
done
echo "[OK] Keycloak disponible"

# --- Obtenir un token admin ---
echo "[INFO] Authentification admin..."
ADMIN_TOKEN=$(curl -sf \
  -d "client_id=admin-cli" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

echo "[OK] Token admin obtenu"

auth_header="Authorization: Bearer ${ADMIN_TOKEN}"

# --- Créer le realm "k8s" ---
echo "[INFO] Création du realm '${REALM}'..."
curl -sf -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "k8s",
    "displayName": "Kubernetes Formation",
    "enabled": true,
    "registrationAllowed": false,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "accessTokenLifespan": 3600
  }' \
  "${KEYCLOAK_URL}/admin/realms" || echo "[INFO] Realm déjà existant"

echo "[OK] Realm '${REALM}' prêt"

# --- Créer le client "kubernetes" ---
echo "[INFO] Création du client 'kubernetes'..."
curl -sf -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "kubernetes",
    "name": "Kubernetes API Server",
    "enabled": true,
    "publicClient": true,
    "standardFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "protocol": "openid-connect",
    "attributes": {
      "access.token.lifespan": "3600"
    },
    "protocolMappers": [
      {
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": false,
        "config": {
          "claim.name": "groups",
          "full.path": "false",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      },
      {
        "name": "email",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-usermodel-property-mapper",
        "consentRequired": false,
        "config": {
          "userinfo.token.claim": "true",
          "user.attribute": "email",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "claim.name": "email",
          "jsonType.label": "String"
        }
      }
    ]
  }' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" || echo "[INFO] Client déjà existant"

echo "[OK] Client 'kubernetes' prêt"

# --- Créer le groupe "dev-team" ---
echo "[INFO] Création du groupe 'dev-team'..."
curl -sf -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json" \
  -d '{"name": "dev-team"}' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" || echo "[INFO] Groupe déjà existant"

# Récupérer l'ID du groupe
GROUP_ID=$(curl -sf \
  -H "${auth_header}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/groups?search=dev-team" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "[OK] Groupe 'dev-team' ID=${GROUP_ID}"

# --- Créer l'utilisateur alice ---
echo "[INFO] Création de l'utilisateur 'alice'..."
curl -sf -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "alice",
    "email": "alice@formation.local",
    "firstName": "Alice",
    "lastName": "Dev",
    "enabled": true,
    "emailVerified": true,
    "credentials": [
      {
        "type": "password",
        "value": "alice123",
        "temporary": false
      }
    ]
  }' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users" || echo "[INFO] Utilisateur alice déjà existant"

# Récupérer l'ID d'alice
ALICE_ID=$(curl -sf \
  -H "${auth_header}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=alice" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

# Ajouter alice au groupe dev-team
curl -sf -X PUT \
  -H "${auth_header}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${ALICE_ID}/groups/${GROUP_ID}" || true

echo "[OK] Alice (ID=${ALICE_ID}) créée et ajoutée à dev-team"

# --- Créer l'utilisateur bob ---
echo "[INFO] Création de l'utilisateur 'bob'..."
curl -sf -X POST \
  -H "${auth_header}" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "bob",
    "email": "bob@formation.local",
    "firstName": "Bob",
    "lastName": "Ops",
    "enabled": true,
    "emailVerified": true,
    "credentials": [
      {
        "type": "password",
        "value": "bob123",
        "temporary": false
      }
    ]
  }' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users" || echo "[INFO] Utilisateur bob déjà existant"

BOB_ID=$(curl -sf \
  -H "${auth_header}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=bob" \
  | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "[OK] Bob (ID=${BOB_ID}) créé"

echo ""
echo "======================================================"
echo " Keycloak configuré !"
echo "======================================================"
echo ""
echo "  Realm    : ${REALM}"
echo "  Client   : kubernetes"
echo "  Groupes  : dev-team"
echo "  Users    : alice (alice@formation.local / alice123) → dev-team"
echo "             bob   (bob@formation.local   / bob123)"
echo ""
echo "  Console admin : ${KEYCLOAK_URL}/admin  (admin / admin123)"
echo "  Discovery URL : ${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration"
echo ""
echo "Suite : bash 03-apply-rbac-oidc.sh"
