#!/usr/bin/env python3
"""
01-mutating-webhook-server.py — Serveur de Mutating Admission Webhook
=======================================================================

CAS CONCRET : Injection automatique d'un sidecar de logging Fluentd

Chaque Pod créé dans un namespace labellisé "logging=enabled" reçoit
automatiquement un conteneur fluentd sans que le développeur ait à
le spécifier. C'est le même mécanisme utilisé par Istio pour injecter
Envoy, ou par Vault pour injecter des secrets.

DIFFÉRENCE CLÉE avec le Validating Webhook :
  Validating  → refuse ou accepte, ne modifie RIEN
  Mutating    → modifie l'objet AVANT validation (JSON Patch RFC 6902)

Pipeline d'exécution dans Kubernetes :
  kubectl apply
      │
      ▼  API Server (authn + authz)
      │
      ▼  MUTATING webhooks  ← CE WEBHOOK (modifie le pod)
      │
      ▼  Schema validation
      │
      ▼  VALIDATING webhooks (valide le pod modifié)
      │
      ▼  etcd

Ce que fait ce webhook :
  1. Vérifie si le pod est dans un namespace avec label logging=enabled
  2. Vérifie si un sidecar fluentd existe déjà (idempotence)
  3. Injecte le sidecar fluentd + un volume partagé de logs
  4. Ajoute une annotation "sidecar-injected: true"
  5. Retourne un JSON Patch pour modifier le pod

Format JSON Patch (RFC 6902) :
  [
    {"op": "add", "path": "/spec/containers/-", "value": {...}},
    {"op": "add", "path": "/metadata/annotations/...", "value": "true"}
  ]

Usage :
  python3 01-mutating-webhook-server.py --cert cert.pem --key key.pem
"""

import json
import ssl
import base64
import argparse
import logging
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)


# ─── Client Kubernetes in-cluster ────────────────────────────────────────────
# Quand le pod tourne dans K8s, les credentials sont montés dans /var/run/secrets
# Le token Bearer + le CA cert permettent d'appeler l'API Server depuis un pod

_K8S_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
_K8S_CA_PATH    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
_K8S_API        = "https://kubernetes.default.svc"


def get_namespace_labels(namespace: str) -> dict:
    """
    Récupère les labels d'un namespace via l'API Kubernetes in-cluster.
    Utilise le ServiceAccount monté automatiquement dans le pod.

    POURQUOI : namespaceObject n'est PAS inclus dans l'AdmissionReview par défaut.
    La seule façon fiable de lire les labels du namespace est d'appeler l'API.
    """
    try:
        with open(_K8S_TOKEN_PATH) as f:
            token = f.read().strip()

        url = f"{_K8S_API}/api/v1/namespaces/{namespace}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})

        # Utiliser le CA cert du cluster pour valider le TLS de l'API Server
        import ssl as _ssl
        ctx = _ssl.create_default_context(cafile=_K8S_CA_PATH)

        with urllib.request.urlopen(req, context=ctx, timeout=3) as resp:
            ns_obj = json.loads(resp.read())
            labels = ns_obj.get("metadata", {}).get("labels", {})
            log.debug(f"Labels namespace/{namespace} : {labels}")
            return labels

    except FileNotFoundError:
        # Hors cluster (dev local) : retourner labels vides
        log.warning("Fichiers ServiceAccount absents — mode hors-cluster, injection désactivée")
        return {}
    except Exception as e:
        log.error(f"Erreur lecture namespace/{namespace} : {e}")
        return {}


# ─── Définition du sidecar injecté ───────────────────────────────────────────
# En production, cela viendrait d'un ConfigMap ou d'une config externe

FLUENTD_SIDECAR = {
    "name": "fluentd-sidecar",
    "image": "fluent/fluentd:v1.16-1",
    "resources": {
        "requests": {"cpu": "50m", "memory": "64Mi"},
        "limits":   {"cpu": "100m", "memory": "128Mi"},
    },
    "volumeMounts": [
        {
            "name":      "app-logs",
            "mountPath": "/var/log/app",
            "readOnly":  True,
        }
    ],
    "env": [
        {"name": "FLUENTD_ARGS", "value": "--no-supervisor"},
        {
            "name": "POD_NAME",
            "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}},
        },
        {
            "name": "POD_NAMESPACE",
            "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}},
        },
    ],
}

LOG_VOLUME = {
    "name":     "app-logs",
    "emptyDir": {},
}


# ─── Logique de mutation ──────────────────────────────────────────────────────

def should_inject(pod: dict, namespace_labels: dict) -> tuple[bool, str]:
    """
    Décide si le sidecar doit être injecté.
    Retourne (inject: bool, raison: str)
    """
    pod_name = pod.get("metadata", {}).get("name", "?")

    # 1. Opt-out explicite sur le pod : annotation "sidecar-inject: false"
    annotations = pod.get("metadata", {}).get("annotations", {})
    if annotations.get("sidecar-inject") == "false":
        return False, f"pod/{pod_name} a l'annotation sidecar-inject=false (opt-out)"

    # 2. Namespace doit avoir le label logging=enabled
    if namespace_labels.get("logging") != "enabled":
        return False, f"Namespace sans label logging=enabled — injection ignorée"

    # 3. Idempotence : ne pas injecter si déjà présent
    containers = pod.get("spec", {}).get("containers", [])
    for c in containers:
        if c.get("name") == "fluentd-sidecar":
            return False, f"pod/{pod_name} a déjà un sidecar fluentd"

    return True, f"pod/{pod_name} éligible à l'injection"


def build_patch(pod: dict) -> list:
    """
    Construit un JSON Patch RFC 6902 pour injecter le sidecar.

    Opérations disponibles : add, remove, replace, move, copy, test
    Ici on utilise uniquement "add".

    ATTENTION aux chemins JSON Pointer (RFC 6901) :
      /spec/containers/-   → ajoute à la fin de la liste
      /metadata/annotations → remplace le dictionnaire entier si absent
    """
    patch = []

    # ── S'assurer que annotations existe ────────────────────────────────────
    # Si le pod n'a aucune annotation, on doit d'abord créer l'objet vide
    if "annotations" not in pod.get("metadata", {}):
        patch.append({
            "op":    "add",
            "path":  "/metadata/annotations",
            "value": {},
        })

    # ── Marquer le pod comme muté ────────────────────────────────────────────
    patch.append({
        "op":    "add",
        "path":  "/metadata/annotations/sidecar-injected",
        "value": "true",
    })
    patch.append({
        "op":    "add",
        "path":  "/metadata/annotations/sidecar-injected-by",
        "value": "mutating-webhook.formation.local",
    })

    # ── Injecter le volume partagé ───────────────────────────────────────────
    # Si aucun volume n'existe encore, il faut créer la liste
    if not pod.get("spec", {}).get("volumes"):
        patch.append({
            "op":    "add",
            "path":  "/spec/volumes",
            "value": [],
        })

    patch.append({
        "op":    "add",
        "path":  "/spec/volumes/-",   # "-" = append à la fin
        "value": LOG_VOLUME,
    })

    # ── Injecter le sidecar fluentd ──────────────────────────────────────────
    patch.append({
        "op":    "add",
        "path":  "/spec/containers/-",
        "value": FLUENTD_SIDECAR,
    })

    return patch


def mutate_pod(uid: str, pod: dict, namespace_labels: dict) -> dict:
    """
    Point d'entrée de la mutation.
    Retourne un AdmissionResponse avec patch base64 ou sans patch (pass-through).
    """
    inject, reason = should_inject(pod, namespace_labels)
    pod_name = pod.get("metadata", {}).get("name", "?")

    if not inject:
        log.info(f"SKIP injection: {reason}")
        return {"uid": uid, "allowed": True}

    patch = build_patch(pod)
    patch_bytes  = json.dumps(patch).encode()
    patch_b64    = base64.b64encode(patch_bytes).decode()

    log.info(
        f"INJECT sidecar → pod/{pod_name} "
        f"({len(patch)} opérations JSON Patch)"
    )
    for op in patch:
        log.info(f"  {op['op']:7s} {op['path']}")

    return {
        "uid":       uid,
        "allowed":   True,
        # patchType DOIT être "JSONPatch" (seul type supporté)
        "patchType": "JSONPatch",
        # patch encodé en base64
        "patch":     patch_b64,
    }


# ─── Serveur HTTP ─────────────────────────────────────────────────────────────

PATH_MUTATE = "/mutate-pods"
PATH_HEALTH = "/healthz"


class MutatingWebhookHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        # Vérifier le path AVANT de lire le body
        # L'API Server a un timeout global — toute opération bloquante avant
        # ce check peut faire expirer la requête côté API Server
        # L'API Server ajoute ?timeout=10s au path → comparer uniquement le début
        base_path = self.path.split("?")[0]

        if base_path not in (PATH_MUTATE, PATH_HEALTH):
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"not found"}')
            return

        if base_path == PATH_HEALTH:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            review = json.loads(body)
        except json.JSONDecodeError as e:
            log.error(f"JSON invalide : {e}")
            self.send_response(400)
            self.end_headers()
            return

        request          = review.get("request", {})
        uid              = request.get("uid", "")
        obj              = request.get("object", {})
        op               = request.get("operation", "")
        ns               = request.get("namespace", "?")
        # Récupérer les labels du namespace via l'API K8s (namespaceObject absent par défaut)
        namespace_labels = get_namespace_labels(ns)

        log.info(
            f"→ {op} pod/{obj.get('metadata',{}).get('name','?')} "
            f"(ns:{ns}) "
            f"labels_ns={namespace_labels}"
        )

        response = mutate_pod(uid, obj, namespace_labels)

        admission_review = {
            "apiVersion": "admission.k8s.io/v1",
            "kind":       "AdmissionReview",
            "response":   response,
        }

        resp_body = json.dumps(admission_review).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

    def do_GET(self):
        if self.path.split("?")[0] == PATH_HEALTH:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # Désactive les logs HTTP par défaut


def main():
    parser = argparse.ArgumentParser(description="Mutating Admission Webhook — Sidecar Injector")
    parser.add_argument("--cert", default="cert.pem", help="Certificat TLS")
    parser.add_argument("--key",  default="key.pem",  help="Clé privée TLS")
    parser.add_argument("--port", type=int, default=8443, help="Port HTTPS")
    args = parser.parse_args()

    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    # Forcer HTTP/1.1 — HTTPServer Python ne supporte pas HTTP/2 (ALPN h2)
    # Sans ça, l'API Server K8s négocie h2, la connexion échoue avec
    # "the server could not find the requested resource"
    ssl_ctx.set_alpn_protocols(["http/1.1"])
    ssl_ctx.load_cert_chain(args.cert, args.key)

    server = HTTPServer(("0.0.0.0", args.port), MutatingWebhookHandler)
    server.socket = ssl_ctx.wrap_socket(server.socket, server_side=True)

    log.info(f"Mutating webhook démarré sur https://0.0.0.0:{args.port}/mutate-pods")
    log.info("Comportement :")
    log.info("  - Namespaces avec label logging=enabled → sidecar fluentd injecté")
    log.info("  - Pods avec annotation sidecar-inject=false → ignorés (opt-out)")
    log.info("  - Pods ayant déjà un sidecar fluentd → ignorés (idempotence)")
    log.info("En attente de requêtes...")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Serveur arrêté")


if __name__ == "__main__":
    main()
