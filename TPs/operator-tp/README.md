# TP — Créer un Opérateur Kubernetes : Trivy Image Scanner

## Objectifs pédagogiques

À la fin de ce TP, vous serez capables de :
- Créer une CRD (Custom Resource Definition) pour définir un nouveau type Kubernetes
- Comprendre et implémenter une boucle de réconciliation
- Utiliser le framework **kopf** pour écrire un opérateur en Python
- Observer le comportement d'un opérateur en temps réel


**Prérequis :** Cluster kind actif, `pip install kopf kubernetes`

---

## Contexte

Votre équipe sécurité veut pouvoir scanner les images Docker utilisées dans le cluster pour détecter les vulnérabilités (CVEs). Plutôt que de lancer `trivy image ...` à la main, vous allez créer un **opérateur Kubernetes** qui automatise ce travail.

L'utilisateur final pourra faire :

```bash
kubectl apply -f - <<EOF
apiVersion: security.formation.local/v1
kind: ImageScan
metadata:
  name: scan-nginx
spec:
  image: nginx:1.27-alpine
  severity: HIGH
EOF
```

Et quelques instants plus tard :

```bash
kubectl get imagescans
# NAME         IMAGE               PHASE       CRITICAL   HIGH
# scan-nginx   nginx:1.27-alpine   Completed   0          15
```

---

## Architecture cible

```
┌─────────────────────────────────────────────────────────┐
│                    Cluster Kubernetes                    │
│                                                         │
│   kubectl apply ImageScan CR                            │
│          │                                              │
│          ▼                                              │
│   ┌─────────────┐    Watch     ┌──────────────────┐    │
│   │  API Server  │ ──────────► │  Trivy Operator   │    │
│   │  (ImageScan) │             │  (votre code)     │    │
│   └─────────────┘             └────────┬─────────┘    │
│          ▲                             │               │
│          │ PATCH status                │ create Job    │
│          │                             ▼               │
│          │                    ┌──────────────────┐    │
│          └────────────────────│   Job Trivy       │    │
│                                │   (scan image)    │    │
│                                └──────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Étape 1 — Installer la CRD

La CRD définit le nouveau type `ImageScan` dans Kubernetes. Elle est fournie dans `01-imagescans-crd.yaml`.

```bash
kubectl apply -f 01-imagescans-crd.yaml
kubectl wait --for=condition=Established \
    crd/imagescans.security.formation.local --timeout=30s
```

**Vérification :**
```bash
kubectl api-resources | grep imagescans
kubectl explain imagescan.spec
```

> **Question :** Que définit le champ `additionalPrinterColumns` dans la CRD ?
> Observez la différence entre `kubectl get imagescans` et `kubectl get imagescans -o yaml`.

---

## Étape 2 — Créer un ImageScan manuellement

Avant d'écrire l'opérateur, créez un CR à la main pour comprendre la structure.

```bash
kubectl apply -f - <<EOF
apiVersion: security.formation.local/v1
kind: ImageScan
metadata:
  name: mon-premier-scan
  namespace: default
spec:
  image: alpine:3.11
  severity: CRITICAL
EOF
```

```bash
kubectl get imagescans
kubectl get imagescan mon-premier-scan -o yaml
```

> **Observation :** Le CR est créé mais `PHASE` est vide — il n'y a pas encore d'opérateur pour le traiter.

Supprimez ce CR avant de continuer :
```bash
kubectl delete imagescan mon-premier-scan
```

---

## Étape 3 — Comprendre le code de l'opérateur

Le fichier `python-kopf/operator.py` vous est fourni. Lisez-le et répondez aux questions suivantes avant de le lancer.

### 3.1 Les décorateurs kopf

```python
@kopf.on.create('security.formation.local', 'v1', 'imagescans')
def on_imagescan_create(spec, name, namespace, logger, patch, **kwargs):
    ...
```

> **Question 1 :** Que fait le décorateur `@kopf.on.create` ?
> **Question 2 :** Pourquoi les arguments `spec`, `name`, `patch` sont-ils injectés automatiquement ?
> **Question 3 :** Quel est le rôle de `patch.status` ?

### 3.2 Le timer

```python
@kopf.timer('security.formation.local', 'v1', 'imagescans', interval=30.0)
def check_scan_progress(spec, status, name, namespace, logger, patch, **kwargs):
    ...
```

> **Question 4 :** Pourquoi a-t-on besoin d'un timer en plus du `on.create` ?
> **Question 5 :** Que se passe-t-il si on supprime le timer ? Quand le status `Completed` serait-il mis à jour ?

### 3.3 Le Job Trivy

Cherchez la fonction `_build_trivy_job` dans le code.

> **Question 6 :** Pourquoi utilise-t-on `--exit-code 0` dans la commande trivy ?
> **Question 7 :** Que fait `ttlSecondsAfterFinished: 300` ?
> **Question 8 :** Pourquoi `backoffLimit: 0` et pas `3` ?

---

## Étape 4 — Lancer l'opérateur

```bash
cd python-kopf
kopf run operator.py --verbose
```

Laissez ce terminal ouvert. Dans un **second terminal**, créez les CRs :

```bash
kubectl apply -f ../02-imagescans-examples.yaml
```

**Observez en temps réel :**

```bash
# Terminal 3 — suivre les scans
kubectl get imagescans -w

# Terminal 4 — suivre les Jobs créés
kubectl get jobs -w

# Terminal 5 — suivre les Pods
kubectl get pods -w
```

> **Observation :** Notez l'ordre des événements dans les logs kopf :
> 1. `on_imagescan_create` est appelé → Job créé
> 2. `check_scan_progress` timer → vérifie le Job toutes les 30s
> 3. Job terminé → status mis à jour

---

## Étape 5 — Lire les résultats

Une fois les scans terminés (`PHASE = Completed`) :

```bash
kubectl get imagescans
```

```bash
# Détail complet d'un scan
kubectl get imagescan scan-old-alpine -o yaml
```

> **Question 9 :** Combien de CVEs CRITICAL a `alpine:3.11` ?
> **Question 10 :** Pourquoi `nginx:1.27-alpine` a des HIGH mais pas de CRITICAL ?

---

## Étape 6 — Exercice : modifier l'opérateur

### Exercice A — Ajouter un champ `scannedAt` dans le status

Modifiez `on_imagescan_create` pour ajouter la date du scan dans le status :

```python
# Dans on_imagescan_create, après avoir récupéré les résultats :
patch.status['scannedAt'] = datetime.now(timezone.utc).isoformat()
```

Vérifiez avec :
```bash
kubectl get imagescan scan-old-alpine -o jsonpath='{.status.scannedAt}'
```

---

### Exercice B — Rejeter les images vulnérables (webhook + opérateur)

Modifiez le timer `check_scan_progress` pour passer la phase à `"Rejected"` si le nombre de CRITICAL est supérieur à 0 :

```python
# À compléter dans check_scan_progress, après avoir obtenu les résultats :
if results['critical'] > 0:
    patch.status['phase'] = 'Rejected'
    patch.status['summary'] = f"Image rejetée: {results['critical']} CVE critiques"
```

> **Réflexion :** Comment iriez-vous plus loin pour **bloquer le déploiement** d'une image qui a des CVEs critiques dans le cluster ? (indice : demo 02 — admission webhooks)

---

### Exercice C — Ajouter un champ `maxCritical` dans le Spec

Modifiez la CRD `01-imagescans-crd.yaml` pour ajouter un champ optionnel :

```yaml
maxCritical:
  type: integer
  default: 0
  description: "Nombre maximum de CVEs critiques tolérées"
```

Puis modifiez l'opérateur pour utiliser ce champ :
```python
max_critical = spec.get('maxCritical', 0)
if results['critical'] > max_critical:
    patch.status['phase'] = 'Rejected'
```
