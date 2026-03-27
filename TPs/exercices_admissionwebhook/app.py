"""
Validating Admission Webhook - Contrôle des Labels Obligatoires
================================================================
Ce webhook intercepte les requêtes de création/mise à jour de Pods
et vérifie que les labels "team" et "env" sont présents.

Si l'un des labels est manquant, la requête est rejetée avec un
message explicatif.
"""

from flask import Flask, request, jsonify
import json

app = Flask(__name__)

# Labels obligatoires sur chaque Pod
REQUIRED_LABELS = ["team", "env"]


@app.route("/healthz", methods=["GET"])
def healthz():
    """Endpoint de health check pour la readinessProbe."""
    return "ok", 200


@app.route("/validate", methods=["POST"])
def validate():
    """
    Point d'entrée principal du webhook.
    Kubernetes envoie une AdmissionReview en JSON.
    On inspecte les labels du Pod et on accepte ou refuse.
    """
    admission_review = request.get_json()

    # Extraire la requête
    admission_request = admission_review.get("request", {})
    uid = admission_request.get("uid", "")

    # Extraire l'objet Pod soumis
    pod = admission_request.get("object", {})
    metadata = pod.get("metadata", {})
    labels = metadata.get("labels", {})
    pod_name = metadata.get("name") or metadata.get("generateName", "<inconnu>")

    # Vérifier la présence des labels obligatoires
    missing = [label for label in REQUIRED_LABELS if label not in labels]

    if missing:
        # REFUS : il manque des labels
        return jsonify({
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": False,
                "status": {
                    "code": 403,
                    "message": (
                        f"Pod '{pod_name}' rejeté : labels obligatoires manquants : "
                        f"{', '.join(missing)}. "
                        f"Chaque Pod doit avoir les labels : {', '.join(REQUIRED_LABELS)}"
                    )
                }
            }
        })

    # Vérifier que les labels ne sont pas vides
    empty = [label for label in REQUIRED_LABELS if not labels.get(label, "").strip()]

    if empty:
        return jsonify({
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": uid,
                "allowed": False,
                "status": {
                    "code": 403,
                    "message": (
                        f"Pod '{pod_name}' rejeté : les labels suivants sont vides : "
                        f"{', '.join(empty)}. "
                        f"Les labels obligatoires doivent avoir une valeur non vide."
                    )
                }
            }
        })

    # ACCEPTÉ : tous les labels sont présents et non vides
    app.logger.info(f"Pod '{pod_name}' accepté (team={labels['team']}, env={labels['env']})")

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": uid,
            "allowed": True
        }
    })


if __name__ == "__main__":
    # Le webhook DOIT tourner en HTTPS (TLS)
    app.run(
        host="0.0.0.0",
        port=8443,
        ssl_context=("/certs/tls.crt", "/certs/tls.key")
    )
