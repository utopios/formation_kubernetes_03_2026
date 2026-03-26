#!/usr/bin/env bash
# =============================================================================
# 02-user-x509.sh — Créer un utilisateur Alice via certificat X.509
# Usage : bash 02-user-x509.sh
# Prérequis : cluster Kind actif (bash 00-setup-kind.sh)
# =============================================================================
set -euo pipefail

USER="alice"
GROUP="dev-team"
CLUSTER="formation-k8s"

echo "=== Génération de la clé et du CSR pour ${USER} ==="
openssl genrsa -out "${USER}.key" 2048
openssl req -new -key "${USER}.key" \
  -subj "/CN=${USER}/O=${GROUP}" \
  -out "${USER}.csr"

echo "=== Soumission du CertificateSigningRequest à Kubernetes ==="
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER}
spec:
  request: $(base64 -w0 "${USER}.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - client auth
EOF

echo "=== Approbation du CSR ==="
kubectl certificate approve "${USER}"

echo "=== Récupération du certificat signé ==="
kubectl get csr "${USER}" -o jsonpath='{.status.certificate}' | base64 -d > "${USER}.crt"

echo "=== Configuration du contexte kubectl ==="
kubectl config set-credentials "${USER}" \
  --client-certificate="${USER}.crt" \
  --client-key="${USER}.key"

kubectl config set-context "${USER}-ctx" \
  --cluster="${CLUSTER}" \
  --user="${USER}" \
  --namespace="dev"

echo ""
echo "=== Test : Alice sans RBAC (doit être Forbidden) ==="
kubectl --context="${USER}-ctx" get pods -n dev 2>&1 || true

echo ""
echo "=== Certificat créé pour ${USER} (CN=${USER}, O=${GROUP}) ==="
openssl x509 -in "${USER}.crt" -noout -subject -dates
echo ""
echo "Contexte disponible : kubectl --context=${USER}-ctx get pods"
echo "Appliquer le RBAC  : kubectl apply -f 03-role-rolebinding.yaml"
