#!/usr/bin/env python3
"""
01-validating-webhook-server.py — Serveur de Validating Admission Webhook
==========================================================================

Ce serveur HTTPS intercepte les requêtes de création/modification de Pods
et applique des règles de sécurité :

  RÈGLE 1 : Les images sans tag précis (latest, sha256) sont bloquées
  RÈGLE 2 : Les containers root (runAsUser: 0) sont bloqués
  RÈGLE 3 : Les containers sans requests.cpu sont bloqués
  RÈGLE 4 : Les namespaces sans label "policy-enforced" sont exemptés

Pipeline d'exécution dans Kubernetes :
  kubectl apply → API Server → MUTATING webhooks → VALIDATING webhooks → etcd

Usage :
  python3 01-validating-webhook-server.py --cert cert.pem --key key.pem
  # Dans un autre terminal :
  # kubectl apply -f 02-webhook-config.yaml
  # kubectl apply -f 03-test-pods.yaml

Format des échanges (AdmissionReview) :
  Requête  : {uid, kind, resource, object, oldObject, operation, userInfo}
  Réponse  : {uid, allowed: bool, status: {code, message}}
"""

import json
import ssl
import argparse
import logging
import re
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    pass

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)


def validate_pod(uid: str, pod: dict) -> dict:
    """
    Logique de validation principale.
    Retourne un AdmissionResponse : allowed=True/False + message d'erreur.
    """
    spec      = pod.get("spec", {})
    containers = spec.get("containers", []) + spec.get("initContainers", [])
    violations = []

    for container in containers:
        image = container.get("image", "")
        name  = container.get("name", "?")

        # ── RÈGLE 1 : Pas de tag :latest ─────────────────────────────────
        # :latest est imprévisible — l'image peut changer sans alerte
        if image.endswith(":latest") or ":" not in image:
            violations.append(
                f"Container '{name}': image '{image}' utilise ':latest' ou n'a pas de tag. "
                f"Utilisez un tag précis (ex: nginx:1.25.3)"
            )

        # ── RÈGLE 2 : Pas de root ────────────────────────────────────────
        sec_ctx = container.get("securityContext", {})
        if sec_ctx.get("runAsUser") == 0:
            violations.append(
                f"Container '{name}': runAsUser=0 (root) interdit. "
                f"Utilisez un UID non-privilégié (ex: runAsUser: 1000)"
            )

        # ── RÈGLE 3 : requests.cpu obligatoire ───────────────────────────
        # Sans requests.cpu, le scheduler ne peut pas placer le pod correctement
        resources = container.get("resources", {})
        if not resources.get("requests", {}).get("cpu"):
            violations.append(
                f"Container '{name}': resources.requests.cpu manquant. "
                f"Obligatoire pour le scheduling et le HPA"
            )

    if violations:
        message = " | ".join(violations)
        log.info(f"REFUSED pod/{pod.get('metadata',{}).get('name','?')} : {len(violations)} violation(s)")
        return {
            "uid":     uid,
            "allowed": False,
            "status": {
                "code":    422,
                "message": f"Pod rejeté ({len(violations)} violation(s)) : {message}",
            }
        }

    log.info(f"ALLOWED pod/{pod.get('metadata',{}).get('name','?')}")
    return {"uid": uid, "allowed": True}


class WebhookHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.path.startswith("/validate-pods"):
            self.send_response(404)
            self.end_headers()
            return

        # Lire le corps de la requête
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            review = json.loads(body)
        except json.JSONDecodeError as e:
            log.error(f"JSON invalide : {e}")
            self.send_response(400)
            self.end_headers()
            return

        request  = review.get("request", {})
        uid      = request.get("uid", "")
        obj      = request.get("object", {})
        op       = request.get("operation", "")

        log.info(f"→ {op} pod/{obj.get('metadata',{}).get('name','?')} "
                 f"(ns: {request.get('namespace','?')}) "
                 f"by {request.get('userInfo',{}).get('username','?')}")

        # Construire la réponse AdmissionReview
        response = validate_pod(uid, obj)
        admission_review = {
            "apiVersion": "admission.k8s.io/v1",
            "kind":       "AdmissionReview",
            "response":   response,
        }

        body = json.dumps(admission_review).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        log.info("HTTP %s", format % args)


def main():
    parser = argparse.ArgumentParser(description="Validating Admission Webhook")
    parser.add_argument("--cert", default="cert.pem", help="Certificat TLS")
    parser.add_argument("--key",  default="key.pem",  help="Clé privée TLS")
    parser.add_argument("--port", type=int, default=8443, help="Port HTTPS")
    args = parser.parse_args()

    # L'API Server EXIGE HTTPS pour les webhooks (même en dev)
    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_ctx.load_cert_chain(args.cert, args.key)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), WebhookHandler)
    server.socket = ssl_ctx.wrap_socket(server.socket, server_side=True)

    log.info(f"Webhook server démarré sur https://0.0.0.0:{args.port}/validate-pods")
    log.info("Règles actives :")
    log.info("  1. Images :latest ou sans tag → REFUSÉ")
    log.info("  2. runAsUser: 0 (root) → REFUSÉ")
    log.info("  3. resources.requests.cpu manquant → REFUSÉ")
    log.info("En attente de requêtes...")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Serveur arrêté")


if __name__ == "__main__":
    main()
