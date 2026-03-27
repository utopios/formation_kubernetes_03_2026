#!/usr/bin/env bash
# =============================================================================
# 04-setup-mutating-webhook.sh — Déploiement complet du Mutating Webhook
#
# Ce script :
#   1. Génère les certificats TLS (CA custom + certificat serveur avec SAN)
#   2. Crée le namespace + RBAC
#   3. Upload le code Python dans un ConfigMap
#   4. Crée le Secret TLS
#   5. Déploie le serveur webhook
#   6. Enregistre la MutatingWebhookConfiguration avec le bon caBundle
#   7. Lance les tests des 4 scénarios
#   8. Vérifie que le sidecar a bien été injecté
#
# Prérequis :
#   - kubectl configuré et connecté au cluster
#   - openssl installé
#   - Un cluster Kubernetes (kind, minikube, etc.)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Couleurs
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
step()    { echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${GREEN}▶ $*${NC}"; }

NAMESPACE="webhook-mutating-system"
SERVICE="webhook-server"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 1 — Génération des certificats TLS"
# ─────────────────────────────────────────────────────────────────────────────
# Même logique que pour le validating webhook :
# L'API Server DOIT vérifier le TLS du webhook
# → Certificat auto-signé avec une CA custom dont on passe le bundle

info "Génération de la CA..."
openssl genrsa -out "$WORK_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 365 \
    -key "$WORK_DIR/ca.key" \
    -subj "/C=FR/O=Formation/CN=mutating-webhook-ca" \
    -out "$WORK_DIR/ca.crt" 2>/dev/null

info "Génération du certificat serveur avec SAN..."
openssl genrsa -out "$WORK_DIR/server.key" 2048 2>/dev/null
openssl req -new \
    -key "$WORK_DIR/server.key" \
    -subj "/C=FR/O=Formation/CN=${SERVICE}.${NAMESPACE}.svc" \
    -out "$WORK_DIR/server.csr" 2>/dev/null

# Le SAN DOIT correspondre exactement au DNS du Service K8s
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

# caBundle = CA certificate en base64 — injecté dans la MutatingWebhookConfiguration
CA_BUNDLE=$(base64 < "$WORK_DIR/ca.crt" | tr -d '\n')
success "Certificats TLS générés (CA + server cert avec SAN)"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 2 — Création du namespace et du RBAC"
# ─────────────────────────────────────────────────────────────────────────────

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" skip-mutating-webhook=true --overwrite

# Créer les namespaces de test
kubectl create namespace logging-enabled  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace logging-disabled --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace logging-enabled logging=enabled --overwrite

# ServiceAccount + RBAC pour lire les namespaces
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webhook-server
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: webhook-namespace-reader
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: webhook-namespace-reader
subjects:
  - kind: ServiceAccount
    name: webhook-server
    namespace: $NAMESPACE
roleRef:
  kind: ClusterRole
  name: webhook-namespace-reader
  apiGroup: rbac.authorization.k8s.io
EOF

success "Namespace + RBAC créés"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 3 — Upload du code webhook"
# ─────────────────────────────────────────────────────────────────────────────

kubectl create configmap webhook-code \
    -n "$NAMESPACE" \
    --from-file=webhook-server.py="$SCRIPT_DIR/01-mutating-webhook-server.py" \
    --dry-run=client -o yaml | kubectl apply -f -

success "ConfigMap webhook-code créé"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 4 — Création du Secret TLS et déploiement"
# ─────────────────────────────────────────────────────────────────────────────

kubectl create secret tls webhook-server-tls \
    -n "$NAMESPACE" \
    --cert="$WORK_DIR/server.crt" \
    --key="$WORK_DIR/server.key" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-server
  namespace: $NAMESPACE
  labels:
    app: webhook-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: webhook-server
  template:
    metadata:
      labels:
        app: webhook-server
      annotations:
        sidecar-inject: "false"
    spec:
      serviceAccountName: webhook-server
      containers:
        - name: webhook
          image: python:3.11-slim
          command: ["python3", "/app/webhook-server.py"]
          args:
            - "--cert=/tls/tls.crt"
            - "--key=/tls/tls.key"
            - "--port=8443"
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
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
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
      name: https
EOF

info "Attente du démarrage des pods webhook..."
# Attendre que le Deployment crée effectivement les pods avant le wait
kubectl rollout status deployment/webhook-server -n "$NAMESPACE" --timeout=120s
success "Webhook server opérationnel (2 replicas)"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 5 — Enregistrement de la MutatingWebhookConfiguration"
# ─────────────────────────────────────────────────────────────────────────────
# C'est ici qu'on spécifie kind: MutatingWebhookConfiguration
# et qu'on injecte le caBundle pour que l'API Server valide le TLS

info "caBundle (début) : ${CA_BUNDLE:0:40}..."

kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector-webhook
webhooks:
  - name: sidecar-injector.formation.local
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    timeoutSeconds: 10
    reinvocationPolicy: IfNeeded
    clientConfig:
      service:
        name: webhook-server
        namespace: $NAMESPACE
        path: "/mutate-pods"
        port: 443
      caBundle: "$CA_BUNDLE"
    rules:
      - operations: ["CREATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        scope: "Namespaced"
    namespaceSelector:
      matchLabels:
        logging: enabled
      matchExpressions:
        - key: skip-mutating-webhook
          operator: DoesNotExist
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - kube-system
            - kube-public
            - $NAMESPACE
EOF

success "MutatingWebhookConfiguration enregistrée"

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 6 — Tests des 4 scénarios"
# ─────────────────────────────────────────────────────────────────────────────

sleep 5  # Laisser le webhook s'initialiser complètement

# ── TEST 1 : Injection normale ────────────────────────────────────────────────
info "TEST 1 : Pod dans namespace logging=enabled (injection attendue)"
kubectl apply -f - <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-injected
  namespace: logging-enabled
  labels:
    test: "1-injection-normale"
spec:
  containers:
    - name: app
      image: nginx:1.25.3
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
PODEOF

# ── TEST 2 : Opt-out ──────────────────────────────────────────────────────────
info "TEST 2 : Pod avec annotation sidecar-inject=false (pas d'injection)"
kubectl apply -f - <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-optout
  namespace: logging-enabled
  annotations:
    sidecar-inject: "false"
spec:
  containers:
    - name: app
      image: nginx:1.25.3
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
PODEOF

# ── TEST 3 : Namespace sans label ─────────────────────────────────────────────
info "TEST 3 : Pod dans namespace sans logging=enabled (webhook non invoqué)"
kubectl apply -f - <<'PODEOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-no-label
  namespace: logging-disabled
spec:
  containers:
    - name: app
      image: nginx:1.25.3
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
PODEOF

sleep 10  # Attendre que les pods soient créés

# ─────────────────────────────────────────────────────────────────────────────
step "ÉTAPE 7 — Vérification des résultats"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "── TEST 1 : Containers dans test-injected ──────────────────────────────"
CONTAINERS=$(kubectl get pod test-injected -n logging-enabled \
    -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "pod non trouvé")
echo "  Containers : $CONTAINERS"
if echo "$CONTAINERS" | grep -q "fluentd-sidecar"; then
    success "CORRECT — fluentd-sidecar présent dans test-injected"
else
    error "ÉCHEC — fluentd-sidecar absent de test-injected"
fi

echo ""
echo "  Annotations du pod muté :"
kubectl get pod test-injected -n logging-enabled \
    -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool || true

echo ""
echo "── TEST 2 : Containers dans test-optout ────────────────────────────────"
CONTAINERS2=$(kubectl get pod test-optout -n logging-enabled \
    -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "pod non trouvé")
echo "  Containers : $CONTAINERS2"
if echo "$CONTAINERS2" | grep -qv "fluentd-sidecar" && ! echo "$CONTAINERS2" | grep -q "fluentd"; then
    success "CORRECT — pas de sidecar dans test-optout (opt-out respecté)"
else
    error "ÉCHEC — sidecar présent malgré l'opt-out"
fi

echo ""
echo "── TEST 3 : Containers dans test-no-label ──────────────────────────────"
CONTAINERS3=$(kubectl get pod test-no-label -n logging-disabled \
    -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || echo "pod non trouvé")
echo "  Containers : $CONTAINERS3"
if ! echo "$CONTAINERS3" | grep -q "fluentd"; then
    success "CORRECT — pas de sidecar dans namespace sans label"
else
    error "ÉCHEC — sidecar injecté dans namespace non labellisé"
fi

echo ""
echo "── Logs du webhook server ──────────────────────────────────────────────"
kubectl logs -n "$NAMESPACE" -l app=webhook-server --tail=30 2>&1

# ─────────────────────────────────────────────────────────────────────────────
step "RÉSUMÉ"
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF'

  ARCHITECTURE DU MUTATING WEBHOOK :
  ────────────────────────────────────────────────────────────────────────
  kubectl apply pod
      │
      ▼  API Server (authn + authz)
      │
      ├─► MutatingWebhookConfiguration (sidecar-injector-webhook)
      │     POST /mutate-pods  { AdmissionReview }
      │     ← { allowed: true, patchType: "JSONPatch", patch: "base64..." }
      │     Le patch est appliqué : fluentd-sidecar + volume app-logs ajoutés
      │
      ▼  Schema validation (le pod muté est validé)
      │
      ▼  ValidatingWebhooks (sur le pod déjà muté)
      │
      ▼  etcd — le pod final contient le sidecar

  JSON PATCH RFC 6902 appliqué par le webhook :
  ────────────────────────────────────────────────────────────────────────
  [
    {"op":"add","path":"/metadata/annotations/sidecar-injected","value":"true"},
    {"op":"add","path":"/spec/volumes/-","value":{"name":"app-logs","emptyDir":{}}},
    {"op":"add","path":"/spec/containers/-","value":{"name":"fluentd-sidecar",...}}
  ]

  COMMANDES UTILES :
  ────────────────────────────────────────────────────────────────────────
  # Voir la config du webhook
  kubectl get mutatingwebhookconfigurations
  kubectl describe mutatingwebhookconfiguration sidecar-injector-webhook

  # Inspecter un pod muté
  kubectl get pod test-injected -n logging-enabled -o yaml | grep -A5 containers:
  kubectl get pod test-injected -n logging-enabled -o jsonpath='{.spec.containers[*].name}'

  # Voir les logs du webhook server en temps réel
  kubectl logs -n webhook-mutating-system -l app=webhook-server -f

  NETTOYAGE :
  ────────────────────────────────────────────────────────────────────────
  kubectl delete mutatingwebhookconfiguration sidecar-injector-webhook
  kubectl delete namespace webhook-mutating-system logging-enabled logging-disabled
  kubectl delete clusterrole webhook-namespace-reader
  kubectl delete clusterrolebinding webhook-namespace-reader

EOF

success "Démo Mutating Admission Webhook terminée !"
