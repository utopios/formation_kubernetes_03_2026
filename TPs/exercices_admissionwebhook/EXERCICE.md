# Exercice : Déployer un Validating Admission Webhook — Contrôle des Labels

## Objectif

Déployer dans Kubernetes un **Validating Admission Webhook** qui **refuse la création
de tout Pod ne portant pas les labels `team` et `env`**.

Le code Python du webhook (`app.py`), le `Dockerfile` et le `requirements.txt`
vous sont fournis. **Votre travail** est de :

1. Builder et rendre disponible l'image Docker du webhook
2. Créer **tous les manifests Kubernetes** nécessaires à son fonctionnement
3. Tester que le webhook accepte et refuse correctement les Pods

---

## Fichiers fournis

| Fichier            | Description                                        |
|--------------------|----------------------------------------------------|
| `app.py`           | Serveur Flask exposant `/validate` (HTTPS, port 8443) |
| `Dockerfile`       | Image Docker du webhook                            |
| `requirements.txt` | Dépendances Python                                 |

---

## Travail à réaliser

### Étape 1 — Builder l'image Docker

Construire l'image et la pousser dans un registry accessible par votre cluster
(Docker Hub, registry local, ou `kind load docker-image` / `minikube image load`
selon votre environnement).

### Étape 2 — Générer les certificats TLS

Le webhook Kubernetes **doit** communiquer en HTTPS. Vous devez générer un
couple certificat/clé et les stocker dans un **Secret Kubernetes** de type `tls`.

**Indice** : Le CN (Common Name) du certificat doit correspondre au format
`<nom-du-service>.<namespace>.svc`.

### Étape 3 — Créer les manifests Kubernetes

Vous devez écrire les manifests YAML suivants :

1. **Namespace** (optionnel) : un namespace dédié au webhook (ex: `webhook-system`)

2. **Secret TLS** : contenant le certificat et la clé privée (type `kubernetes.io/tls`)

3. **Deployment** : déploie le pod du webhook
   - Monte le secret TLS dans `/certs`
   - Expose le port 8443
   - Inclut une `readinessProbe` sur `/healthz`

4. **Service** : expose le Deployment en ClusterIP sur le port 443 → targetPort 8443

5. **ValidatingWebhookConfiguration** : le manifest central qui dit à Kubernetes
   d'appeler votre webhook. Points d'attention :
   - `rules` : intercepter les opérations `CREATE` sur les ressources `pods`
   - `clientConfig.service` : pointer vers votre Service
   - `clientConfig.caBundle` : le certificat CA encodé en **base64**
   - `failurePolicy` : choisir `Fail` ou `Ignore` (réfléchissez aux implications)
   - `namespaceSelector` : ajouter un sélecteur pour ne PAS intercepter le
     namespace `kube-system` ni le namespace du webhook lui-même

### Étape 4 — Déployer et vérifier

```bash
# Appliquer vos manifests
kubectl apply -f <vos-fichiers.yaml>

# Vérifier que le pod du webhook tourne
kubectl get pods -n webhook-system

# Vérifier les logs du webhook
kubectl logs -n webhook-system -l app=label-webhook
```

### Étape 5 — Tester

#### Test 1 : Pod sans labels (doit être REFUSÉ)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-no-labels
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

```bash
kubectl apply -f test-pod-no-labels.yaml
# Attendu : Error from server: admission webhook "..." denied the request: ...
```

#### Test 2 : Pod avec un seul label (doit être REFUSÉ)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-partial
  labels:
    team: backend
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

#### Test 3 : Pod avec les deux labels (doit être ACCEPTÉ)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-valid
  labels:
    team: backend
    env: staging
spec:
  containers:
    - name: nginx
      image: nginx:latest
```

#### Test 4 : Pod avec un label vide (doit être REFUSÉ)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-empty-label
  labels:
    team: ""
    env: production
spec:
  containers:
    - name: nginx
      image: nginx:latest
```


