#!/usr/bin/env bash
# =============================================================================
# 00-setup-k3d-oidc.sh — Cluster k3d avec OIDC (Keycloak HTTPS + CA auto-signé)
# Usage    : bash 00-setup-k3d-oidc.sh
# Prérequis : k3d, kubectl, openssl installés
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="formation-oidc"
KEYCLOAK_HOST="keycloak.formation.local"
KUBECONFIG_FILE="/tmp/oidc-kubeconfig"
export KUBECONFIG="${KUBECONFIG_FILE}"

echo "======================================================"
echo " Setup k3d OIDC — Formation Kubernetes"
echo "======================================================"

# --- Nettoyage cluster existant ---
if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  echo "[INFO] Suppression du cluster existant..."
  k3d cluster delete "${CLUSTER_NAME}" 2>/dev/null || true
  sleep 2
fi

# --- Étape 1 : Générer le CA (pas encore le cert Keycloak) ---
echo "[INFO] Génération du CA..."
mkdir -p "${SCRIPT_DIR}/certs"

openssl genrsa -out "${SCRIPT_DIR}/certs/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 365 \
  -key "${SCRIPT_DIR}/certs/ca.key" \
  -subj "/CN=formation-ca/O=Utopios" \
  -out "${SCRIPT_DIR}/certs/ca.crt" 2>/dev/null

echo "[OK] CA généré"

# --- Étape 2 : Créer le cluster k3d avec un oidc-issuer-url temporaire ---
# On utilisera l'IP réelle du server-0 après création
echo "[INFO] Création du cluster k3d (phase 1 — sans OIDC)..."
cat > /tmp/k3d-formation-phase1.yaml <<EOF
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: ${CLUSTER_NAME}
servers: 1
agents: 2
volumes:
  - volume: "${SCRIPT_DIR}/certs/ca.crt:/etc/ssl/certs/formation-ca.crt"
    nodeFilters:
      - server:*
      - agent:*
ports:
  - port: "30443:30443"
    nodeFilters:
      - server:0
  - port: "31080:30080"
    nodeFilters:
      - server:0
EOF

k3d cluster create --config=/tmp/k3d-formation-phase1.yaml

echo "[INFO] Cluster créé. Récupération de l'IP du server-0..."
SERVER_IP=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
echo "[OK] IP server-0 : ${SERVER_IP}"

# --- Étape 3 : Générer le cert Keycloak avec l'IP réelle ---
echo "[INFO] Génération du certificat Keycloak avec SAN IP:${SERVER_IP}..."
openssl genrsa -out "${SCRIPT_DIR}/certs/keycloak.key" 2048 2>/dev/null
openssl req -new \
  -key "${SCRIPT_DIR}/certs/keycloak.key" \
  -subj "/CN=${KEYCLOAK_HOST}" \
  -out "${SCRIPT_DIR}/certs/keycloak.csr" 2>/dev/null

cat > "${SCRIPT_DIR}/certs/keycloak.ext" <<EXTEOF
subjectAltName=DNS:${KEYCLOAK_HOST},IP:${SERVER_IP},IP:127.0.0.1
EXTEOF

openssl x509 -req -days 365 \
  -in "${SCRIPT_DIR}/certs/keycloak.csr" \
  -CA "${SCRIPT_DIR}/certs/ca.crt" \
  -CAkey "${SCRIPT_DIR}/certs/ca.key" \
  -CAcreateserial \
  -extfile "${SCRIPT_DIR}/certs/keycloak.ext" \
  -out "${SCRIPT_DIR}/certs/keycloak.crt" 2>/dev/null

echo "[OK] Certificat Keycloak généré avec SAN: DNS:${KEYCLOAK_HOST}, IP:${SERVER_IP}"

# --- Étape 4 : Recréer le cluster avec les flags OIDC corrects ---
echo "[INFO] Suppression du cluster temporaire..."
k3d cluster delete "${CLUSTER_NAME}" 2>/dev/null || true
sleep 2

echo "[INFO] Recréation du cluster k3d avec flags OIDC (oidc-issuer-url=https://${SERVER_IP}:30443/realms/k8s)..."
cat > "${SCRIPT_DIR}/k3d-config.yaml" <<EOF
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: ${CLUSTER_NAME}
servers: 1
agents: 2
volumes:
  - volume: "${SCRIPT_DIR}/certs/ca.crt:/etc/ssl/certs/formation-ca.crt"
    nodeFilters:
      - server:*
      - agent:*
options:
  k3s:
    extraArgs:
      - arg: "--kube-apiserver-arg=oidc-issuer-url=https://${SERVER_IP}:30443/realms/k8s"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-client-id=kubernetes"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-username-claim=email"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-groups-claim=groups"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-username-prefix=oidc:"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-groups-prefix=oidc:"
        nodeFilters:
          - server:*
      - arg: "--kube-apiserver-arg=oidc-ca-file=/etc/ssl/certs/formation-ca.crt"
        nodeFilters:
          - server:*
ports:
  - port: "30443:30443"
    nodeFilters:
      - server:0
  - port: "31080:30080"
    nodeFilters:
      - server:0
EOF

k3d cluster create --config="${SCRIPT_DIR}/k3d-config.yaml"

# Vérifier que l'IP du server-0 est bien la même
NEW_SERVER_IP=$(docker inspect "k3d-${CLUSTER_NAME}-server-0" \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

if [ "${NEW_SERVER_IP}" != "${SERVER_IP}" ]; then
  echo "[WARN] IP différente ! Attendu: ${SERVER_IP}, Obtenu: ${NEW_SERVER_IP}"
  echo "[INFO] Régénération du certificat avec la nouvelle IP..."
  cat > "${SCRIPT_DIR}/certs/keycloak.ext" <<EXTEOF
subjectAltName=DNS:${KEYCLOAK_HOST},IP:${NEW_SERVER_IP},IP:127.0.0.1
EXTEOF
  openssl x509 -req -days 365 \
    -in "${SCRIPT_DIR}/certs/keycloak.csr" \
    -CA "${SCRIPT_DIR}/certs/ca.crt" \
    -CAkey "${SCRIPT_DIR}/certs/ca.key" \
    -CAcreateserial \
    -extfile "${SCRIPT_DIR}/certs/keycloak.ext" \
    -out "${SCRIPT_DIR}/certs/keycloak.crt" 2>/dev/null
  SERVER_IP="${NEW_SERVER_IP}"
fi

echo "[OK] Cluster ${CLUSTER_NAME} prêt — server-0 IP: ${SERVER_IP}"
kubectl get nodes

# --- Namespaces ---
echo "[INFO] Création des namespaces..."
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev      --dry-run=client -o yaml | kubectl apply -f -

# --- Secret TLS Keycloak ---
echo "[INFO] Création du secret TLS Keycloak..."
kubectl create secret tls keycloak-tls \
  --cert="${SCRIPT_DIR}/certs/keycloak.crt" \
  --key="${SCRIPT_DIR}/certs/keycloak.key" \
  -n keycloak --dry-run=client -o yaml | kubectl apply -f -

# Copier le CA dans les nodes pour qu'ils fassent confiance au cert Keycloak
echo "[INFO] Injection du CA dans les nodes k3d..."
for node in $(k3d node list --cluster "${CLUSTER_NAME}" -o json 2>/dev/null | grep '"name"' | grep -v tools | cut -d'"' -f4); do
  docker cp "${SCRIPT_DIR}/certs/ca.crt" "${node}:/etc/ssl/certs/formation-ca.crt" 2>/dev/null || true
done

# --- Patch Keycloak YAML avec KC_HOSTNAME_URL ---
echo "[INFO] Configuration de Keycloak avec KC_HOSTNAME_URL=https://${SERVER_IP}:30443..."
sed "s|KC_HOSTNAME_URL_PLACEHOLDER|https://${SERVER_IP}:30443|g" \
  "${SCRIPT_DIR}/01-keycloak.yaml.tpl" > /tmp/01-keycloak-patched.yaml 2>/dev/null || \
  kubectl apply -f "${SCRIPT_DIR}/01-keycloak.yaml"

# --- Déploiement Keycloak ---
echo "[INFO] Déploiement de Keycloak..."
kubectl apply -f "${SCRIPT_DIR}/01-keycloak.yaml"

# Patch KC_HOSTNAME_URL avec l'IP du server (pour forcer l'issuer)
kubectl set env deployment/keycloak -n keycloak \
  "KC_HOSTNAME_URL=https://${SERVER_IP}:30443" \
  "KC_HOSTNAME_ADMIN_URL=https://${SERVER_IP}:30443" 2>/dev/null || true

echo "[INFO] Attente du démarrage Keycloak (peut prendre 2-3 min)..."
kubectl wait --for=condition=Available deployment/keycloak \
  -n keycloak --timeout=300s

# Patch NodePort HTTP pour correspondre au port-mapping k3d (31080→30080)
kubectl patch svc keycloak -n keycloak --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/1/nodePort","value":30080}]' 2>/dev/null || true

echo ""
echo "======================================================"
echo " Cluster k3d OIDC prêt !"
echo "======================================================"
kubectl get nodes
echo ""
echo "  server-0 IP        : ${SERVER_IP}"
echo "  Keycloak HTTPS     : https://${SERVER_IP}:30443"
echo "  Keycloak HTTP (LB) : http://localhost:31080"
echo "  OIDC Issuer URL    : https://${SERVER_IP}:30443/realms/k8s"
echo "  kubeconfig         : ${KUBECONFIG_FILE}"
echo ""
echo "Suite : bash 02-configure-keycloak.sh"
