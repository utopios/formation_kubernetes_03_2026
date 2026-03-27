"""
Trivy Operator - Version Python avec Kopf
==========================================
Framework: kopf (Kubernetes Operator Pythonic Framework) par Zalando
Docs: https://kopf.readthedocs.io/

Kopf gère pour nous :
  - Le Watch de l'API Kubernetes (longpolling)
  - La boucle de réconciliation
  - La gestion des erreurs et retries
  - Les finalizers pour le cleanup

On se concentre uniquement sur la logique métier.

Installation:
  pip install kopf kubernetes

Lancement local (pour développement):
  kopf run operator.py --verbose
"""

import kopf
import kubernetes
import json
import logging
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Handler: déclenché à la CRÉATION d'un ImageScan
# ---------------------------------------------------------------------------
@kopf.on.create('security.formation.local', 'v1', 'imagescans')
def on_imagescan_create(spec, name, namespace, logger, patch, **kwargs):
    """
    Kopf appelle cette fonction automatiquement quand un ImageScan est créé.
    Le décorateur @kopf.on.create fait tout le Watch/dispatch.
    """
    image = spec['image']
    severity = spec.get('severity', 'HIGH')

    logger.info(f"Nouveau scan demandé: {image} (severity={severity})")

    # 1. Mettre le status à "Scanning"
    patch.status['phase'] = 'Scanning'
    patch.status['startTime'] = datetime.now(timezone.utc).isoformat()

    # 2. Créer un Job Kubernetes qui va lancer Trivy
    job_name = f"trivy-scan-{name}"
    job = _build_trivy_job(job_name, namespace, image, severity)

    batch_v1 = kubernetes.client.BatchV1Api()
    batch_v1.create_namespaced_job(namespace=namespace, body=job)

    logger.info(f"Job Trivy créé: {job_name}")

    # Stocker le nom du job dans le status pour le retrouver plus tard
    patch.status['jobName'] = job_name
    patch.status['phase'] = 'Scanning'


# ---------------------------------------------------------------------------
# Handler: déclenché périodiquement pour vérifier l'avancement
# Kopf relance cette fonction toutes les 30 secondes tant que le scan tourne
# ---------------------------------------------------------------------------
@kopf.timer('security.formation.local', 'v1', 'imagescans', interval=30.0)
def check_scan_progress(spec, status, name, namespace, logger, patch, **kwargs):
    """
    Timer Kopf : appelé toutes les 30s.
    On vérifie si le Job Trivy est terminé et on lit les résultats.
    """
    phase = status.get('phase', 'Pending')

    # Ne rien faire si déjà terminé
    if phase in ('Completed', 'Failed'):
        return

    job_name = status.get('jobName')
    if not job_name:
        return

    batch_v1 = kubernetes.client.BatchV1Api()

    try:
        job = batch_v1.read_namespaced_job(name=job_name, namespace=namespace)
    except kubernetes.client.exceptions.ApiException as e:
        if e.status == 404:
            logger.warning(f"Job {job_name} introuvable, scan marqué Failed")
            patch.status['phase'] = 'Failed'
        return

    # Job terminé avec succès ?
    if job.status.succeeded:
        logger.info(f"Job {job_name} terminé, lecture des résultats...")
        results = _read_trivy_results(job_name, namespace, logger)

        patch.status['phase'] = 'Completed'
        patch.status['completionTime'] = datetime.now(timezone.utc).isoformat()
        patch.status['vulnerabilities'] = results
        patch.status['summary'] = (
            f"Scan terminé: {results['critical']} critical, "
            f"{results['high']} high, {results['total']} total"
        )
        logger.info(patch.status['summary'])

    # Job échoué ?
    elif job.status.failed and job.status.failed >= 3:
        logger.error(f"Job {job_name} a échoué après 3 tentatives")
        patch.status['phase'] = 'Failed'
        patch.status['summary'] = "Échec du scan Trivy"


# ---------------------------------------------------------------------------
# Handler: nettoyage à la SUPPRESSION d'un ImageScan
# ---------------------------------------------------------------------------
@kopf.on.delete('security.formation.local', 'v1', 'imagescans')
def on_imagescan_delete(status, name, namespace, logger, **kwargs):
    """Supprime le Job associé quand l'ImageScan est supprimé."""
    job_name = status.get('jobName')
    if not job_name:
        return

    batch_v1 = kubernetes.client.BatchV1Api()
    try:
        batch_v1.delete_namespaced_job(
            name=job_name,
            namespace=namespace,
            body=kubernetes.client.V1DeleteOptions(propagation_policy='Foreground')
        )
        logger.info(f"Job {job_name} supprimé")
    except kubernetes.client.exceptions.ApiException as e:
        if e.status != 404:
            raise


# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------

def _build_trivy_job(job_name: str, namespace: str, image: str, severity: str) -> dict:
    """
    Construit le manifest du Job Kubernetes qui lance Trivy.
    Trivy scanne l'image et écrit le résultat JSON dans /results/output.json
    via un volume partagé (emptyDir).
    """
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": job_name,
            "namespace": namespace,
            "labels": {"app": "trivy-operator", "scan-job": "true"}
        },
        "spec": {
            "ttlSecondsAfterFinished": 300,  # Auto-supprimé après 5 min
            "backoffLimit": 0,
            "template": {
                "spec": {
                    "restartPolicy": "Never",
                    "containers": [{
                        "name": "trivy",
                        "image": "aquasec/trivy:0.50.1",
                        "command": [
                            "trivy", "image",
                            "--format", "json",
                            "--exit-code", "0",  # Toujours exit 0 même si vulnérabilités trouvées
                            "--severity", severity,
                            image
                        ],
                    }],
                }
            }
        }
    }


def _read_trivy_results(job_name: str, namespace: str, logger) -> dict:
    """
    Lit les résultats du scan depuis les logs du Pod du Job.
    En production, on utiliserait un PVC ou un objet ConfigMap/Secret
    pour persister les résultats JSON complets.
    """
    core_v1 = kubernetes.client.CoreV1Api()

    # Trouver le pod du job
    pods = core_v1.list_namespaced_pod(
        namespace=namespace,
        label_selector=f"job-name={job_name}"
    )

    if not pods.items:
        logger.warning("Aucun pod trouvé pour le job")
        return {"critical": 0, "high": 0, "medium": 0, "low": 0, "total": 0}

    pod_name = pods.items[0].metadata.name

    try:
        # Lire les logs du pod (output JSON de Trivy)
        logs = core_v1.read_namespaced_pod_log(
            name=pod_name,
            namespace=namespace
        )
        # Trivy peut écrire des logs de progression avant le JSON
        # On cherche le début du bloc JSON '{'
        json_start = logs.find('{"SchemaVersion"')
        if json_start == -1:
            json_start = logs.find('{')
        report = json.loads(logs[json_start:])
        return _parse_trivy_report(report)
    except Exception as e:
        logger.error(f"Erreur lecture résultats: {e}")
        return {"critical": 0, "high": 0, "medium": 0, "low": 0, "total": 0}


def _parse_trivy_report(report: dict) -> dict:
    """Parse le JSON Trivy et compte les vulnérabilités par sévérité."""
    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0, "total": 0}

    for result in report.get("Results", []):
        for vuln in result.get("Vulnerabilities", []) or []:
            severity = vuln.get("Severity", "").lower()
            if severity in counts:
                counts[severity] += 1
            counts["total"] += 1

    return counts

@kopf.on.event('batch', 'v1', 'jobs')
def on_job_event(event,body, logger, **kwargs):
    """Handler pour les événements sur les Jobs (optionnel, pour debug)."""
    job = event['object']
    job_status = body.get('status', {})
    if not job_status.get('succeeded') and not job_status.get('failed'):
        return  # Ignorer les événements sur les jobs en cours
    job_name = job.metadata.name
    namespace = job.metadata.namespace
    scan_name = job_name.remove_prefix("trivy-scan-")
    if job_status.get('succeeded'):
        # Mettre à jour le status de l'ImageScan associé
        logger.info(f"Job {job_name} terminé avec succès pour ImageScan {scan_name}")
    elif job_status.get('failed'):
        logger.error(f"Job {job_name} a échoué pour ImageScan {scan_name}")
    logger.info(f"Événement Job: {job.metadata.name} - {event['type']}")