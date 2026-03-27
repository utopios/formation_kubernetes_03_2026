#!/bin/bash
# =============================================================================
# deploy.sh — Build, certificats TLS, manifests et déploiement du webhook
# Usage : bash deploy.sh [--kind-cluster <nom>] [--cleanup]
# =============================================================================
set -euo pipefail

# ---------- Configuration ----------------------------------------------------
IMAGE_NAME="label-webhook"
IMAGE_TAG="v1"
NAMESPACE="webhook-system"
SERVICE_NAME="label-webhook"
KIND_CLUSTER="${KIND_CLUSTER:-formation-k8s}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # dossier contenant app.py / Dockerfile
CERTS_DIR="$SCRIPT_DIR/certs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[deploy]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}    $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

# ---------- Analyse des arguments --------------------------------------------
CLEANUP=false
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP=true ;;
    --kind-cluster) shift; KIND_CLUSTER="$1" ;;
  esac
done

# ---------- Nettoyage complet ------------------------------------------------
if [[ "$CLEANUP" == "true" ]]; then
  log "Nettoyage de l'environnement..."
  kubectl delete validatingwebhookconfiguration label-webhook 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace test-webhook 2>/dev/null || true
  rm -rf "$CERTS_DIR"
  ok "Nettoyage terminé."
  exit 0
fi

# ---------- Vérification des prérequis ---------------------------------------
log "Vérification des prérequis..."
for cmd in docker kubectl kind openssl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' est requis mais non trouvé dans le PATH."
done

# Vérifier que le cluster kind cible est actif
kubectl cluster-info &>/dev/null || die "Aucun cluster Kubernetes accessible. Vérifiez votre kubeconfig."
ok "Prérequis OK."

# =============================================================================
# ÉTAPE 1 — Build de l'image Docker
# =============================================================================
log "=== Étape 1 : Build de l'image Docker ==="

[[ -f "$APP_DIR/Dockerfile" ]] || die "Dockerfile introuvable dans $APP_DIR"

docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$APP_DIR" \
  || die "Échec du docker build."

ok "Image ${IMAGE_NAME}:${IMAGE_TAG} construite."

# =============================================================================
# ÉTAPE 2 — Chargement de l'image dans kind
# =============================================================================
log "=== Étape 2 : Chargement de l'image dans kind (cluster: $KIND_CLUSTER) ==="

kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "$KIND_CLUSTER" \
  || die "Échec du kind load. Vérifiez que le cluster '$KIND_CLUSTER' existe."

ok "Image chargée dans le cluster kind."

# =============================================================================
# ÉTAPE 3 — Génération des certificats TLS
# =============================================================================
log "=== Étape 3 : Génération des certificats TLS ==="

mkdir -p "$CERTS_DIR"

SVC_DNS="${SERVICE_NAME}.${NAMESPACE}.svc"

# CA (Certificate Authority auto-signé)
openssl genrsa -out "$CERTS_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 365 \
  -key "$CERTS_DIR/ca.key" \
  -subj "/CN=label-webhook-ca/O=k8s-formation" \
  -out "$CERTS_DIR/ca.crt" 2>/dev/null

# Clé et CSR du serveur
openssl genrsa -out "$CERTS_DIR/tls.key" 2048 2>/dev/null
openssl req -new \
  -key "$CERTS_DIR/tls.key" \
  -subj "/CN=${SVC_DNS}/O=k8s-formation" \
  -out "$CERTS_DIR/tls.csr" 2>/dev/null

# Extension SAN (Subject Alternative Name) — obligatoire pour Kubernetes
cat > "$CERTS_DIR/ext.cnf" <<EOF
[v3_ext]
subjectAltName = DNS:${SVC_DNS},DNS:${SVC_DNS}.cluster.local
EOF

# Signer le certificat serveur avec le CA
openssl x509 -req \
  -in "$CERTS_DIR/tls.csr" \
  -CA "$CERTS_DIR/ca.crt" \
  -CAkey "$CERTS_DIR/ca.key" \
  -CAcreateserial \
  -days 365 \
  -extensions v3_ext \
  -extfile "$CERTS_DIR/ext.cnf" \
  -out "$CERTS_DIR/tls.crt" 2>/dev/null

# Encoder en base64 (sans saut de ligne) pour les manifests Kubernetes
CA_BUNDLE=$(base64 < "$CERTS_DIR/ca.crt"  | tr -d '\n')
TLS_CRT=$(base64   < "$CERTS_DIR/tls.crt" | tr -d '\n')
TLS_KEY=$(base64   < "$CERTS_DIR/tls.key" | tr -d '\n')

ok "Certificats TLS générés dans $CERTS_DIR"
ok "  CA  : $CERTS_DIR/ca.crt"
ok "  Cert: $CERTS_DIR/tls.crt  (CN=${SVC_DNS})"
ok "  Key : $CERTS_DIR/tls.key"

# =============================================================================
# ÉTAPE 4 — Génération des manifests Kubernetes
# =============================================================================
log "=== Étape 4 : Génération des manifests Kubernetes ==="

# 4-1 Namespace
cat > "$SCRIPT_DIR/01-namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    webhook: "false"
EOF

# 4-2 Secret TLS
cat > "$SCRIPT_DIR/02-secret-tls.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: label-webhook-tls
  namespace: ${NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: ${TLS_CRT}
  tls.key: ${TLS_KEY}
EOF

# 4-3 Deployment
cat > "$SCRIPT_DIR/03-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: label-webhook
  namespace: webhook-system
  labels:
    app: label-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: label-webhook
  template:
    metadata:
      labels:
        app: label-webhook
    spec:
      containers:
        - name: webhook
          image: label-webhook:v1
          imagePullPolicy: Never
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: tls-certs
              mountPath: /certs
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 20
      volumes:
        - name: tls-certs
          secret:
            secretName: label-webhook-tls
EOF

# 4-4 Service
cat > "$SCRIPT_DIR/04-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
spec:
  selector:
    app: label-webhook
  ports:
    - port: 443
      targetPort: 8443
EOF

# 4-5 ValidatingWebhookConfiguration
cat > "$SCRIPT_DIR/05-webhook-config.yaml" <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: label-webhook
webhooks:
  - name: label-webhook.${NAMESPACE}.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    namespaceSelector:
      matchExpressions:
        - key: webhook
          operator: NotIn
          values: ["false"]
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        name: ${SERVICE_NAME}
        namespace: ${NAMESPACE}
        path: /validate
        port: 443
      caBundle: ${CA_BUNDLE}
EOF

ok "Manifests générés."

# =============================================================================
# ÉTAPE 5 — Déploiement sur Kubernetes
# =============================================================================
log "=== Étape 5 : Déploiement sur Kubernetes ==="

kubectl apply -f "$SCRIPT_DIR/01-namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/02-secret-tls.yaml"
kubectl apply -f "$SCRIPT_DIR/03-deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/04-service.yaml"

log "Attente que le Pod webhook soit Ready..."
kubectl wait --for=condition=ready pod \
  -l app=label-webhook \
  -n "$NAMESPACE" \
  --timeout=90s \
  || die "Le pod webhook n'est pas devenu Ready dans les temps."

kubectl apply -f "$SCRIPT_DIR/05-webhook-config.yaml"

ok "Déploiement terminé."
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""

# =============================================================================
# ÉTAPE 6 — Tests de validation
# =============================================================================
log "=== Étape 6 : Tests ==="

TEST_NS="test-webhook"
PASS=0
FAIL=0

kubectl create namespace "$TEST_NS" 2>/dev/null || true
# Exclure l'éventuel autre webhook présent sur le cluster de formation
kubectl label namespace "$TEST_NS" skip-webhook-validation= 2>/dev/null || true

# Nettoyage des pods de test précédents
kubectl delete pod test-pod-no-labels test-pod-partial test-pod-valid test-pod-empty-label \
  -n "$TEST_NS" 2>/dev/null || true

# run_test <desc> <expected: refused|accepted> <yaml_file>
run_test() {
  local desc="$1" expected="$2" yaml_file="$3"
  local out rc=0
  out=$(kubectl apply -n "$TEST_NS" -f "$yaml_file" 2>&1) || rc=$?
  if [[ "$expected" == "refused" && $rc -ne 0 ]]; then
    echo -e "${GREEN}[PASS]${NC} $desc"
    echo "       → $(echo "$out" | grep -o 'denied.*' | head -1)"
    PASS=$((PASS+1))
  elif [[ "$expected" == "accepted" && $rc -eq 0 ]]; then
    echo -e "${GREEN}[PASS]${NC} $desc"
    PASS=$((PASS+1))
  else
    echo -e "${RED}[FAIL]${NC} $desc"
    echo "       → $out"
    FAIL=$((FAIL+1))
  fi
}

# Générer les fichiers de test YAML
cat > /tmp/t1-no-labels.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-no-labels
spec:
  containers:
    - name: nginx
      image: nginx:latest
YAML

cat > /tmp/t2-partial.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-partial
  labels:
    team: backend
spec:
  containers:
    - name: nginx
      image: nginx:latest
YAML

cat > /tmp/t3-valid.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-valid
  labels:
    team: backend
    env: staging
spec:
  containers:
    - name: nginx
      image: nginx:latest
YAML

cat > /tmp/t4-empty-label.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-empty-label
  labels:
    team: ""
    env: production
spec:
  containers:
    - name: nginx
      image: nginx:latest
YAML

run_test "Test 1 : Pod sans labels → REFUSÉ"     "refused"  /tmp/t1-no-labels.yaml
run_test "Test 2 : Pod avec team seul → REFUSÉ"  "refused"  /tmp/t2-partial.yaml
run_test "Test 3 : Pod avec team+env → ACCEPTÉ"  "accepted" /tmp/t3-valid.yaml
run_test "Test 4 : Pod avec label vide → REFUSÉ" "refused"  /tmp/t4-empty-label.yaml

echo ""
echo "============================================"
echo " Résultat : ${PASS} PASS / $((PASS+FAIL)) tests"
echo "============================================"
[[ $FAIL -eq 0 ]] && ok "Tous les tests sont passés !" || warn "$FAIL test(s) ont échoué."

echo ""
log "Logs du webhook (10 dernières lignes) :"
kubectl logs -n "$NAMESPACE" -l app=label-webhook --tail=10
