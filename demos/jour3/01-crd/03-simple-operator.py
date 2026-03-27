import time
import logging
from kubernetes import client, config, watch

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger(__name__)

# Groupe/Version/Ressource de notre CRD
GROUP   = "platform.formation.local"
VERSION = "v1"
PLURAL  = "microservices"


def reconcile(custom_api, apps_api, core_api, ms: dict):
    """
    Boucle de réconciliation principale.
    Appelée à chaque événement (ADDED, MODIFIED, DELETED).
    Doit être IDEMPOTENTE : appeler 10 fois = même résultat qu'appeler 1 fois.
    """
    namespace = ms["metadata"]["namespace"]
    name      = ms["metadata"]["name"]
    spec      = ms.get("spec", {})

    image    = spec.get("image", "nginx:latest")
    replicas = spec.get("replicas", 1)
    port     = spec.get("port", 8080)
    team     = spec.get("team", "unknown")
    env_vars = spec.get("env", {})

    log.info(f"Reconciling Microservice {namespace}/{name} (image={image}, replicas={replicas})")

    # ── 1. Construire les labels communs ──────────────────────────────────
    labels = {
        "app":            name,
        "managed-by":     "ms-operator",
        "team":           team,
        "ms.platform/name": name,
    }

    # ── 2. Créer ou mettre à jour le Deployment ────────────────────────────
    env_list = [
        client.V1EnvVar(name=k, value=v)
        for k, v in env_vars.items()
    ]

    deployment = client.V1Deployment(
        metadata=client.V1ObjectMeta(
            name=name,
            namespace=namespace,
            labels=labels,
            # OwnerReference : le Deployment sera supprimé si la CR est supprimée
            owner_references=[{
                "apiVersion": f"{GROUP}/{VERSION}",
                "kind":       "Microservice",
                "name":       name,
                "uid":        ms["metadata"]["uid"],
                "controller": True,
                "blockOwnerDeletion": True,
            }]
        ),
        spec=client.V1DeploymentSpec(
            replicas=replicas,
            selector=client.V1LabelSelector(match_labels={"app": name}),
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels=labels),
                spec=client.V1PodSpec(
                    containers=[client.V1Container(
                        name=name,
                        image=image,
                        ports=[client.V1ContainerPort(container_port=port)],
                        env=env_list,
                    )]
                )
            )
        )
    )

    try:
        # Tente de créer — si existe déjà, met à jour
        apps_api.create_namespaced_deployment(namespace=namespace, body=deployment)
        log.info(f"  → Deployment {name} créé")
    except client.exceptions.ApiException as e:
        if e.status == 409:  # Already exists
            apps_api.patch_namespaced_deployment(name=name, namespace=namespace, body=deployment)
            log.info(f"  → Deployment {name} mis à jour")
        else:
            raise

    # ── 3. Créer le Service si expose=true ─────────────────────────────────
    if spec.get("expose", False):
        service = client.V1Service(
            metadata=client.V1ObjectMeta(
                name=name,
                namespace=namespace,
                labels=labels,
            ),
            spec=client.V1ServiceSpec(
                selector={"app": name},
                ports=[client.V1ServicePort(port=port, target_port=port)],
                type="ClusterIP"
            )
        )
        try:
            core_api.create_namespaced_service(namespace=namespace, body=service)
            log.info(f"  → Service {name} créé")
        except client.exceptions.ApiException as e:
            if e.status == 409:
                core_api.patch_namespaced_service(name=name, namespace=namespace, body=service)
                log.info(f"  → Service {name} mis à jour")
            else:
                raise

    # ── 4. Mettre à jour le STATUS de la CR ───────────────────────────────
    # L'opérateur observe les pods créés pour calculer readyReplicas
    try:
        pods = core_api.list_namespaced_pod(
            namespace=namespace,
            label_selector=f"app={name},managed-by=ms-operator"
        )
        ready = sum(
            1 for p in pods.items
            if p.status.phase == "Running" and
               all(c.ready for c in (p.status.container_statuses or []))
        )
        phase = "Running" if ready == replicas else "Pending"
    except Exception:
        ready = 0
        phase = "Pending"

    status_patch = {
        "status": {
            "phase": phase,
            "readyReplicas": ready,
            "message": f"{ready}/{replicas} replicas ready",
        }
    }

    try:
        custom_api.patch_namespaced_custom_object_status(
            group=GROUP,
            version=VERSION,
            namespace=namespace,
            plural=PLURAL,
            name=name,
            body=status_patch,
        )
        log.info(f"  → Status mis à jour : {phase} ({ready}/{replicas} ready)")
    except Exception as e:
        log.warning(f"  ⚠ Impossible de mettre à jour le status : {e}")


def delete_resources(apps_api, core_api, namespace: str, name: str):
    """Nettoyage quand une CR est supprimée (si pas d'ownerReference automatique)."""
    log.info(f"Suppression des ressources pour {namespace}/{name}")
    for api_call in [
        lambda: apps_api.delete_namespaced_deployment(name, namespace),
        lambda: core_api.delete_namespaced_service(name, namespace),
    ]:
        try:
            api_call()
        except client.exceptions.ApiException as e:
            if e.status != 404:
                log.warning(f"Erreur suppression : {e}")


def reconcile_all(custom_api, apps_api, core_api):
    """Re-reconcilie toutes les CRs existantes (pour mettre à jour le status après que les pods deviennent Ready)."""
    try:
        result = custom_api.list_cluster_custom_object(group=GROUP, version=VERSION, plural=PLURAL)
        for ms in result.get("items", []):
            try:
                reconcile(custom_api, apps_api, core_api, ms)
            except Exception as e:
                log.error(f"Erreur reconcile (periodic): {e}")
    except Exception as e:
        log.error(f"Erreur list CRs: {e}")


def main():
    log.info("=" * 60)
    log.info(" Microservice Operator démarré")
    log.info(f" Surveille : {GROUP}/{VERSION}/{PLURAL}")
    log.info("=" * 60)

    # Chargement de la config kubeconfig (hors cluster) ou in-cluster
    try:
        config.load_incluster_config()
        log.info("Config: in-cluster")
    except config.ConfigException:
        config.load_kube_config()
        log.info("Config: kubeconfig local")

    custom_api = client.CustomObjectsApi()
    apps_api   = client.AppsV1Api()
    core_api   = client.CoreV1Api()

    RESYNC_INTERVAL = 10  # secondes — re-reconcilie toutes les CRs pour détecter les pods Ready
    last_resync = 0

    w = watch.Watch()
    log.info("Watch démarré — en attente d'événements...")

    # Le watch envoie les événements ADDED/MODIFIED/DELETED
    for event in w.stream(
        custom_api.list_cluster_custom_object,
        group=GROUP,
        version=VERSION,
        plural=PLURAL,
        timeout_seconds=RESYNC_INTERVAL,  # expire le stream pour forcer un re-sync périodique
    ):
        event_type = event["type"]      # ADDED, MODIFIED, DELETED, ERROR
        ms_object  = event["object"]

        if event_type in ("ADDED", "MODIFIED"):
            try:
                reconcile(custom_api, apps_api, core_api, ms_object)
            except Exception as e:
                log.error(f"Erreur reconcile: {e}")

        elif event_type == "DELETED":
            ns   = ms_object["metadata"]["namespace"]
            name = ms_object["metadata"]["name"]
            # Les ownerReferences font le nettoyage automatiquement
            # mais on le fait explicitement ici si l'ownerRef n'était pas posé
            log.info(f"CR {ns}/{name} supprimée — les ressources owned seront nettoyées automatiquement")

        # Re-sync périodique pour mettre à jour le status quand les pods deviennent Ready
        now = time.time()
        if now - last_resync >= RESYNC_INTERVAL:
            log.info("⟳ Re-sync périodique — vérification du status des pods...")
            reconcile_all(custom_api, apps_api, core_api)
            last_resync = now

        time.sleep(0.1)  # Rate limiting basique


if __name__ == "__main__":
    main()