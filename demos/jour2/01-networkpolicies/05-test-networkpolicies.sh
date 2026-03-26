#!/usr/bin/env bash
# =============================================================================
# 05-test-networkpolicies.sh — Script de test des NetworkPolicies
#
# Ce script démontre l'effet des NetworkPolicies en testant les connexions
# AVANT et APRÈS leur application.
#
# Usage : bash 05-test-networkpolicies.sh
# Prérequis : cluster Kind avec Calico, kubectl configuré
# =============================================================================
set -euo pipefail

export KUBECONFIG=/tmp/kind-kubeconfig

TIMEOUT=5  # secondes pour les tests de connexion

echo "======================================================"
echo " Démo NetworkPolicies — Architecture 3-tiers"
echo "======================================================"

# Attendre que tous les pods soient ready
echo "[INFO] Attente des pods..."
kubectl wait --for=condition=Ready pods -l app=frontend -n netpol-frontend --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pods -l app=backend  -n netpol-backend  --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod/attacker -n default --timeout=60s 2>/dev/null || true

FRONTEND_POD=$(kubectl get pod -n netpol-frontend -l app=frontend -o jsonpath='{.items[0].metadata.name}')
BACKEND_POD=$(kubectl get pod -n netpol-backend  -l app=backend  -o jsonpath='{.items[0].metadata.name}')
ATTACKER_POD="attacker"

echo ""
echo "======================================================"
echo " PHASE 1 : SANS NetworkPolicies (tout autorisé)"
echo "======================================================"
echo "[INFO] Suppression des policies existantes..."
kubectl delete networkpolicy --all -n netpol-frontend 2>/dev/null || true
kubectl delete networkpolicy --all -n netpol-backend  2>/dev/null || true
kubectl delete networkpolicy --all -n netpol-db       2>/dev/null || true
sleep 2

echo ""
echo "--- Test 1 : attacker → backend (attendu AVANT deny: OK) ---"
kubectl exec -n default ${ATTACKER_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 | head -3 \
  && echo "[OK] Connexion réussie" || echo "[ECHEC] Connexion refusée"

echo ""
echo "--- Test 2 : frontend → backend (attendu AVANT deny: OK) ---"
kubectl exec -n netpol-frontend ${FRONTEND_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 | head -3 \
  && echo "[OK] Connexion réussie" || echo "[ECHEC] Connexion refusée"

echo ""
echo "--- Test 3 : attacker → database (attendu AVANT deny: OK) ---"
kubectl exec -n default ${ATTACKER_POD} -- \
  nc -zv database.netpol-db.svc.cluster.local 5432 2>&1 \
  && echo "[OK] Connexion réussie" || echo "[ECHEC] Connexion refusée"

echo ""
echo "======================================================"
echo " APPLICATION DU DENY-ALL"
echo "======================================================"
kubectl apply -f "$(dirname "$0")/03-deny-all.yaml"
echo "[INFO] Attente 3s pour propagation des policies..."
sleep 3

echo ""
echo "======================================================"
echo " PHASE 2 : AVEC deny-all (tout bloqué)"
echo "======================================================"

echo ""
echo "--- Test 4 : attacker → backend (attendu APRÈS deny: BLOQUÉ) ---"
kubectl exec -n default ${ATTACKER_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 \
  && echo "[ECHEC] Devrait être bloqué !" || echo "[OK] Connexion bloquée comme prévu"

echo ""
echo "--- Test 5 : frontend → backend (attendu APRÈS deny: BLOQUÉ) ---"
kubectl exec -n netpol-frontend ${FRONTEND_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 \
  && echo "[ECHEC] Devrait être bloqué !" || echo "[OK] Connexion bloquée comme prévu"

echo ""
echo "======================================================"
echo " APPLICATION DES RÈGLES SÉLECTIVES"
echo "======================================================"
kubectl apply -f "$(dirname "$0")/04-allow-frontend-to-backend.yaml"
echo "[INFO] Attente 3s pour propagation..."
sleep 3

echo ""
echo "======================================================"
echo " PHASE 3 : AVEC policies sélectives"
echo "======================================================"

echo ""
echo "--- Test 6 : frontend → backend (attendu: OK) ---"
kubectl exec -n netpol-frontend ${FRONTEND_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 | head -3 \
  && echo "[OK] Frontend peut accéder au backend" || echo "[ECHEC] Le frontend ne peut pas accéder au backend"

echo ""
echo "--- Test 7 : attacker → backend (attendu: BLOQUÉ) ---"
kubectl exec -n default ${ATTACKER_POD} -- \
  wget -qO- --timeout=${TIMEOUT} http://backend.netpol-backend.svc.cluster.local 2>&1 \
  && echo "[ECHEC] L'attaquant ne devrait pas accéder au backend !" || echo "[OK] Attaquant bloqué"

echo ""
echo "--- Test 8 : frontend → database DIRECT (attendu: BLOQUÉ) ---"
kubectl exec -n netpol-frontend ${FRONTEND_POD} -- \
  nc -zv database.netpol-db.svc.cluster.local 5432 2>&1 \
  && echo "[ECHEC] Le frontend ne devrait pas accéder directement à la DB !" || echo "[OK] Accès direct DB bloqué"

echo ""
echo "======================================================"
echo " RÉSUMÉ DES POLICIES"
echo "======================================================"
echo "--- netpol-frontend ---"
kubectl get networkpolicy -n netpol-frontend
echo ""
echo "--- netpol-backend ---"
kubectl get networkpolicy -n netpol-backend
echo ""
echo "--- netpol-db ---"
kubectl get networkpolicy -n netpol-db

echo ""
echo "======================================================"
echo " ✓ Démo terminée"
echo "======================================================"
echo ""
echo "Pour nettoyer : kubectl delete -f 03-deny-all.yaml && kubectl delete -f 04-allow-frontend-to-backend.yaml"
