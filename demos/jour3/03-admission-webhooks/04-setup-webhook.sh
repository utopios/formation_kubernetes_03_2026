#!/usr/bin/env bash
# =============================================================================
# 04-setup-webhook.sh — Setup complet du Validating Admission Webhook
#
# Ce script :
#   1. Génère les certificats TLS pour le serveur webhook
#   2. Crée un ConfigMap contenant le code Python du serveur
#   3. Crée le Secret TLS
#   4. Déploie le serveur webhook
#   5. Configure la ValidatingWebhookConfiguration avec le bon caBundle
#   6. Teste le webhook avec des pods valides et invalides
#
# Prérequis : openssl, kubectl, python3 (pour le serveur)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
step()    { echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${GREEN}▶ $*${NC}"; }

NAMESPACE="webhook-system"
SERVICE="webhook-server"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 1 — Génération des certificats TLS"
# ─────────────────────────────────────────────────────────────────────────────

# L'API Server vérifie le TLS du webhook — certificat auto-signé avec CA custom
info "Génération du CA..."
openssl genrsa -out "$WORK_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 365 -key "$WORK_DIR/ca.key" \
    -subj "/C=FR/O=Formation/CN=webhook-ca" \
    -out "$WORK_DIR/ca.crt" 2>/dev/null

info "Génération du certificat serveur (SAN obligatoire)..."
openssl genrsa -out "$WORK_DIR/server.key" 2048 2>/dev/null
openssl req -new -key "$WORK_DIR/server.key" \
    -subj "/C=FR/O=Formation/CN=${SERVICE}.${NAMESPACE}.svc" \
    -out "$WORK_DIR/server.csr" 2>/dev/null

# Le SAN DOIT correspondre au DNS du Service intra-cluster
cat > "$WORK_DIR/ext.cnf" <<CNF
[v3_req]
subjectAltName = DNS:${SERVICE}.${NAMESPACE}.svc,DNS:${SERVICE}.${NAMESPACE}.svc.cluster.local,DNS:localhost
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
CNF

openssl x509 -req -days 365 \
    -in "$WORK_DIR/server.csr" \
    -CA "$WORK_DIR/ca.crt" \
    -CAkey "$WORK_DIR/ca.key" \
    -CAcreateserial \
    -extfile "$WORK_DIR/ext.cnf" \
    -extensions v3_req \
    -out "$WORK_DIR/server.crt" 2>/dev/null

# caBundle encodé en base64 — passé à la ValidatingWebhookConfiguration
CA_BUNDLE=$(base64 -i "$WORK_DIR/ca.crt" | tr -d '\n')
success "Certificats générés"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 2 — Création du namespace et du code webhook"
# ─────────────────────────────────────────────────────────────────────────────

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" skip-webhook-validation=true --overwrite
kubectl create namespace webhook-test --dry-run=client -o yaml | kubectl apply -f -

# Créer un ConfigMap avec le code Python du serveur webhook
info "Upload du code webhook dans un ConfigMap..."
kubectl create configmap webhook-code \
    -n "$NAMESPACE" \
    --from-file=webhook-server.py="$SCRIPT_DIR/01-validating-webhook-server.py" \
    --dry-run=client -o yaml | kubectl apply -f -

success "ConfigMap webhook-code créé"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 3 — Déploiement du serveur webhook"
# ─────────────────────────────────────────────────────────────────────────────

# Créer le Secret TLS
kubectl create secret tls webhook-server-tls \
    -n "$NAMESPACE" \
    --cert="$WORK_DIR/server.crt" \
    --key="$WORK_DIR/server.key" \
    --dry-run=client -o yaml | kubectl apply -f -

# Appliquer le Deployment et le Service (sans la ValidatingWebhookConfiguration)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-server
  namespace: $NAMESPACE
  labels:
    app: webhook-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webhook-server
  template:
    metadata:
      labels:
        app: webhook-server
    spec:
      containers:
        - name: webhook
          image: python:3.11-slim
          command: ["python3", "/app/webhook-server.py"]
          args: ["--cert", "/tls/tls.crt", "--key", "/tls/tls.key", "--port", "8443"]
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: tls-certs
              mountPath: /tls
              readOnly: true
            - name: webhook-code
              mountPath: /app
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
      volumes:
        - name: tls-certs
          secret:
            secretName: webhook-server-tls
        - name: webhook-code
          configMap:
            name: webhook-code
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-server
  namespace: $NAMESPACE
spec:
  selector:
    app: webhook-server
  ports:
    - port: 443
      targetPort: 8443
EOF

info "Attente du démarrage du webhook server..."
kubectl wait --for=condition=ready pod \
    -l app=webhook-server \
    -n "$NAMESPACE" \
    --timeout=120s
success "Webhook server opérationnel"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 4 — Enregistrement du webhook dans l'API Server"
# ─────────────────────────────────────────────────────────────────────────────

info "caBundle : ${CA_BUNDLE:0:30}..."

kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: pod-policy-webhook
webhooks:
  - name: pod-policy.formation.local
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    timeoutSeconds: 10
    clientConfig:
      service:
        name: webhook-server
        namespace: $NAMESPACE
        path: "/validate-pods"
        port: 443
      caBundle: "$CA_BUNDLE"
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        scope: "Namespaced"
    namespaceSelector:
      matchExpressions:
        - key: skip-webhook-validation
          operator: DoesNotExist
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - kube-system
            - kube-public
            - $NAMESPACE
            - argocd
EOF

success "ValidatingWebhookConfiguration enregistrée"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 5 — Test du webhook"
# ─────────────────────────────────────────────────────────────────────────────

sleep 5  # Laisser le webhook s'initialiser

info "Test 1 : Pod avec image :latest (doit être REFUSÉ)"
if kubectl apply -f - 2>&1 | grep -qE "rejeté|rejected|denied|Forbidden"; then
    success "CORRECT : Pod avec :latest refusé par le webhook"
else
    kubectl apply -f - 2>&1 || true
fi <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-latest
  namespace: webhook-test
spec:
  containers:
    - name: app
      image: nginx:latest
      resources:
        requests:
          cpu: 100m
PODEOF

echo ""
info "Test 2 : Pod avec runAsUser: 0 (doit être REFUSÉ)"
kubectl apply -f - 2>&1 || true <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-bad-root
  namespace: webhook-test
spec:
  containers:
    - name: app
      image: nginx:1.25.3
      securityContext:
        runAsUser: 0
      resources:
        requests:
          cpu: 100m
PODEOF

echo ""
info "Test 3 : Pod valide (doit PASSER)"
kubectl apply -f - 2>&1 && success "CORRECT : Pod valide accepté" <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-good-pod
  namespace: webhook-test
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: app
      image: nginx:1.25.3
      securityContext:
        runAsUser: 1000
        allowPrivilegeEscalation: false
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
PODEOF

echo ""
info "Pods dans webhook-test (seul good-pod devrait exister) :"
kubectl get pods -n webhook-test 2>&1

echo ""
info "Logs du webhook server :"
kubectl logs -n "$NAMESPACE" -l app=webhook-server --tail=20 2>&1

# ─────────────────────────────────────────────────────────────────────────────
step "RÉSUMÉ"
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF'

  ARCHITECTURE DU WEBHOOK :
  ────────────────────────────────────────────────────────────
  kubectl apply pod
      │
      ▼
  API Server (authentification, autorisation)
      │
      ▼
  Mutating webhooks (modification, injection sidecars)
      │
      ▼
  Schema validation (CRD OpenAPI)
      │
      ▼
  Validating webhooks ← NOTRE WEBHOOK ICI
      │  POST /validate-pods avec AdmissionReview JSON
      │  ← réponse: {allowed: true/false, status: {message}}
      ▼
  etcd (stockage si allowed: true)

  COMMANDES UTILES :
  ────────────────────────────────────────────────────────────
  kubectl get validatingwebhookconfigurations
  kubectl describe validatingwebhookconfiguration pod-policy-webhook
  kubectl logs -n webhook-system -l app=webhook-server -f
  kubectl get pods -n webhook-test

  NETTOYAGE :
  ────────────────────────────────────────────────────────────
  kubectl delete validatingwebhookconfiguration pod-policy-webhook
  kubectl delete namespace webhook-system webhook-test

EOF

success "Démo Admission Webhook terminée !"
