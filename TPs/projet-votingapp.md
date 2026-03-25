# Projet fil rouge — Jour 1 : Déploiement de l'application de vote

## L'application

Une application de vote en temps réel avec une architecture découplée : chaque composant fonctionnel est séparé de son interface utilisateur.

### Architecture réelle

```
                        ┌──────────────────────────────────────────────────┐
                        │              Namespace : voting                   │
                        │                                                   │
  Navigateur ──────────►│  [vote-ui]──►[vote]       [result-ui]◄─[result] │
  (vote)     :31000     │  UI vote     Backend        UI résultats  Backend │
  Navigateur ──────────►│  (HTML/JS)   (Python)       (HTML/JS)    (Node)  │
  (résultats):31001     │                 │                   ▲            │
                        │                 ▼                   │            │
                        │             [Redis]          [PostgreSQL]        │
                        │             File de          Base de données      │
                        │             messages         persistante          │
                        │                 │                   ▲            │
                        │                 └──►  [worker]  ────┘            │
                        │                       Consomme Redis,            │
                        │                       écrit dans Postgres        │
                        └──────────────────────────────────────────────────┘
```

### Les 7 composants

| Service | Rôle | Image | Port |
|---------|------|-------|------|
| `vote-ui` | Interface utilisateur de vote (frontend) | `mohamed1780/vote-ui` | 8080 |
| `vote` | Backend de vote — reçoit les votes, écrit dans Redis | `mohamed1780/vote` | 8080 |
| `result-ui` | Interface utilisateur des résultats (frontend) | `mohamed1780/result-ui` | 8080 |
| `result` | Backend résultats — lit PostgreSQL, expose l'API | `mohamed1780/result` | 8080 |
| `worker` | Traitement asynchrone — consomme Redis, écrit dans PostgreSQL | `mohamed1780/worker` | — |
| `redis` | File de messages | `redis:7.2-alpine` | 6379 |
| `db` | Base de données | `postgres:15-alpine` | 5432 |

### Flux de données

1. L'utilisateur vote via **vote-ui** (frontend)
2. **vote-ui** envoie le vote au backend **vote**
3. Le backend **vote** écrit dans **Redis** (file de messages)
4. Le **worker** lit Redis, compte les votes, écrit dans **PostgreSQL**
5. Le backend **result** interroge PostgreSQL et expose l'API de résultats
6. **result-ui** interroge **result** et affiche les résultats en temps réel

---

## Prérequis

Cluster Kind actif avec 3 workers :
```bash
kubectl get nodes
# Attendu : 4 nœuds (1 control-plane + 3 workers) en état Ready
```

---

## Étape 1 — Namespace et quotas

**Objectif :** Isoler l'application dans son propre namespace avec des limites de ressources.

Créer le fichier `01-namespace/namespace.yaml` contenant :

**Namespace** `voting` avec les labels :
- `app: voting-app`
- `environment: dev`
- `team: platform`

**ResourceQuota** `voting-quota` dans ce namespace :
- Maximum 20 pods
- Maximum 4 CPU (requests)
- Maximum 8Gi mémoire (requests)

**LimitRange** `voting-limits` avec les valeurs par défaut par container :
- Request CPU : `100m` / Limit CPU : `500m`
- Request mémoire : `128Mi` / Limit mémoire : `512Mi`

**Validation :**
```bash
kubectl get namespace voting --show-labels
kubectl describe resourcequota voting-quota -n voting
kubectl describe limitrange voting-limits -n voting
```

> **Question :** Déployez un pod sans `resources:` dans le namespace `voting`. Décrivez-le. Quelles valeurs de resources a-t-il reçu ?

---

## Étape 2 — Configuration externalisée

**Objectif :** Externaliser toute la configuration sensible et non-sensible hors des manifests de déploiement.

### ConfigMap `voting-config`

Créer `02-config/configmap.yaml` avec les clés suivantes :
- `OPTION_A` : `Cats`
- `OPTION_B` : `Dogs`
- `REDIS_HOST` : `redis`
- `REDIS_PORT` : `6379`
- `POSTGRES_HOST` : `db`
- `POSTGRES_PORT` : `5432`
- `POSTGRES_DB` : `votes`

### Secret `voting-secrets`

Créer `02-config/secret.yaml` avec :
- `POSTGRES_USER` : `postgres`
- `POSTGRES_PASSWORD` : `v0t1ng-p4ss`

> Les valeurs doivent être encodées en base64 dans le YAML.
> ```bash
> echo -n "v0t1ng-p4ss" | base64
> ```

**Validation :**
```bash
kubectl get configmap voting-config -n voting -o yaml
kubectl get secret voting-secrets -n voting -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

---

## Étape 3 — Base de données PostgreSQL (StatefulSet)

**Objectif :** Déployer PostgreSQL avec persistance garantie. Les votes ne doivent pas être perdus si le pod redémarre.

Créer `03-database/postgres.yaml` contenant :

**Service** `db` de type `ClusterIP` exposant le port 5432 (accessible uniquement depuis le cluster).

**StatefulSet** `db` avec :
- 1 replica
- Image `postgres:15-alpine`
- Variables d'environnement injectées depuis le Secret et le ConfigMap :
  - `POSTGRES_USER` depuis le Secret
  - `POSTGRES_PASSWORD` depuis le Secret
  - `POSTGRES_DB` depuis le ConfigMap
- Un **PVC** de `1Gi` monté sur `/var/lib/postgresql/data`
- Resources : request 200m/256Mi, limit 500m/512Mi

**Validation :**
```bash
kubectl get statefulset db -n voting
kubectl get pvc -n voting
# Connexion à PostgreSQL
kubectl exec -it db-0 -n voting -- psql -U postgres -c "\l"
```

> **Question :** Supprimez le pod PostgreSQL manuellement. Que se passe-t-il ? Combien de temps avant qu'il redémarre ? Les données sont-elles toujours là ?
> ```bash
> kubectl delete pod db-0 -n voting
> kubectl get pods -n voting -w
> kubectl exec -it db-0 -n voting -- psql -U postgres -d votes -c "SELECT * FROM votes LIMIT 5;" 2>/dev/null || echo "Table pas encore créée"
> ```

---

## Étape 4 — Cache Redis (Deployment)

**Objectif :** Déployer Redis comme file de messages entre le service de vote et le worker.

Redis est ici un composant **stateless du point de vue métier** (les votes dans la file sont temporaires — le worker les consomme immédiatement). Un Deployment suffit.

Créer `04-redis/redis.yaml` contenant :

**Service** `redis` de type `ClusterIP` exposant le port 6379.

**Deployment** `redis` avec :
- 1 replica
- Image `redis:7.2-alpine`
- Resources : request 100m/128Mi, limit 200m/256Mi
- Une **readinessProbe** utilisant `exec` avec la commande `redis-cli ping`

**Validation :**
```bash
kubectl get deployment redis -n voting
kubectl exec -it deployment/redis -n voting -- redis-cli ping
# Attendu : PONG
```

> **Question :** Pourquoi Redis utilise ici un Deployment et non un StatefulSet, alors que PostgreSQL utilise un StatefulSet ?

---

## Étape 5 — Worker (Deployment)

**Objectif :** Déployer le composant de traitement asynchrone qui consomme Redis et écrit dans PostgreSQL.

Le worker n'expose aucun port — il ne fait que consommer et écrire. Il a besoin de se connecter aux deux autres services.

Créer `05-worker/worker.yaml` contenant :

**Deployment** `worker` avec :
- 1 replica
- Image `mohamed1780/worker`
- Variables d'environnement depuis le ConfigMap et le Secret :
  - `REDIS_HOST`, `REDIS_PORT` depuis le ConfigMap
  - `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB` depuis le ConfigMap
  - `POSTGRES_USER`, `POSTGRES_PASSWORD` depuis le Secret
- Resources : request 100m/128Mi, limit 500m/256Mi
- **Aucun port** exposé (le worker ne reçoit pas de connexions entrantes)

**Validation :**
```bash
kubectl get deployment worker -n voting
kubectl logs deployment/worker -n voting
# Les logs doivent montrer la connexion à Redis et PostgreSQL
```

---

## Étape 6 — Backend de vote (Deployment + Service interne)

**Objectif :** Déployer le backend qui reçoit les votes et les écrit dans Redis. Ce service est interne — il n'est pas exposé directement à l'extérieur.

Créer `06-vote/vote.yaml` contenant :

**Deployment** `vote` avec :
- 3 replicas
- Image `mohamed1780/vote`
- Variables d'environnement depuis le ConfigMap : `OPTION_A`, `OPTION_B`, `REDIS_HOST`, `REDIS_PORT`
- Variable **Downward API** `POD_NAME` (spec.metadata.name) pour identifier quel pod répond
- **readinessProbe** tcpSocket 5000, initialDelaySeconds: 5
- **livenessProbe** tcpSocket 5000, initialDelaySeconds: 15
- Stratégie `RollingUpdate` avec `maxSurge: 1` et `maxUnavailable: 0`
- Resources : request 100m/128Mi, limit 500m/256Mi

**Service** `vote` de type `ClusterIP` exposant le port 5000 (interne uniquement — accessible par vote-ui).

---

## Étape 7 — Frontend de vote (Deployment + Service externe)

**Objectif :** Déployer l'interface utilisateur du vote, accessible depuis l'extérieur du cluster, qui communique avec le backend `vote`.

Créer `06-vote/vote-ui.yaml` contenant :

**Deployment** `vote-ui` avec :
- 2 replicas
- Image `mohamed1780/vote-ui`
- Variable d'environnement `VOTE_API_URL` : `http://vote:5000` (URL interne du backend)
- **readinessProbe** HTTP sur `/` port 80, initialDelaySeconds: 5
- **livenessProbe** HTTP sur `/` port 80, initialDelaySeconds: 15
- Resources : request 100m/128Mi, limit 500m/256Mi

**Service** `vote-ui` de type `NodePort` exposant le port 80 sur le nodePort `31000`.

**Validation :**
```bash
kubectl get deployment vote vote-ui -n voting
kubectl get pods -n voting -l app=vote -o wide
kubectl get pods -n voting -l app=vote-ui -o wide
curl http://localhost:31000
# Ouvrir dans un navigateur : http://localhost:31000
```

> **Question :** Pourquoi le backend `vote` est-il en `ClusterIP` et pas `NodePort` ? Que se passerait-il si on exposait directement le backend ?

---

## Étape 8 — Backend résultats (Deployment + Service interne)

**Objectif :** Déployer le backend qui lit PostgreSQL et expose l'API des résultats. Ce service est interne — consommé uniquement par result-ui.

Créer `07-result/result.yaml` contenant :

**Deployment** `result` avec :
- 2 replicas
- Image `mohamed1780/result`
- Variables d'environnement depuis le ConfigMap et le Secret : `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- **readinessProbe** TCPSOCKET port 5000
- Resources : request 100m/128Mi, limit 500m/256Mi

**Service** `result` de type `ClusterIP` exposant le port 5000 (interne uniquement — accessible par result-ui).

---

## Étape 9 — Frontend résultats (Deployment + Service externe)

**Objectif :** Déployer l'interface utilisateur des résultats, accessible depuis l'extérieur, qui interroge le backend `result`.

Créer `07-result/result-ui.yaml` contenant :

**Deployment** `result-ui` avec :
- 2 replicas
- Image `mohamed1780/result-ui`
- Variable d'environnement `RESULT_API_URL` : `http://result:5000` (URL interne du backend)
- **readinessProbe** HTTP sur `/` port 80
- Resources : request 100m/128Mi, limit 500m/256Mi

**Service** `result-ui` de type `NodePort` exposant le port 80 sur le nodePort `31001`.

**Validation complète de l'application :**
```bash
# Vérifier que tous les composants sont up
kubectl get all -n voting

# Voter depuis le terminal
curl -X POST http://localhost:31000 -d "vote=a"
curl -X POST http://localhost:31000 -d "vote=b"

# Voir les résultats
curl http://localhost:31001
```

> Ouvrez deux onglets : `http://localhost:31000` (voter) et `http://localhost:31001` (résultats).
> Votez plusieurs fois et observez les résultats se mettre à jour.

---

## Étape 10 — Communication entre services (diagnostic)

**Objectif :** Comprendre et vérifier la résolution DNS entre les services.

Déployer un pod de debug temporaire :
```bash
kubectl run debug --image=busybox:1.36 -n voting --rm -it -- sh
```

Depuis ce pod, effectuer les tests suivants et noter les résultats :

```sh
# 1. Résolution DNS du service Redis
nslookup redis.voting.svc.cluster.local

# 2. Résolution DNS du service PostgreSQL
nslookup db.voting.svc.cluster.local

# 3. Résolution DNS des backends internes
nslookup vote.voting.svc.cluster.local
nslookup result.voting.svc.cluster.local

# 4. Connexion TCP à Redis
nc -zv redis 6379

# 5. Connexion TCP à PostgreSQL
nc -zv db 5432

# 6. Requête HTTP vers le backend vote (depuis l'intérieur)
wget -qO- http://vote:8080 | head -5

# 7. Requête HTTP vers le backend result (depuis l'intérieur)
wget -qO- http://result:8080 | head -5
```

> **Questions :**
> - Quelle est la forme complète d'un nom DNS de service Kubernetes ?
> - Pourquoi peut-on utiliser juste `redis` au lieu de `redis.voting.svc.cluster.local` dans le même namespace ?
> - Que se passe-t-il si vous essayez `nslookup redis` depuis le namespace `default` ?
> - `vote-ui` accède au backend `vote` via `http://vote:8080`. À quoi correspond ce nom DNS ?

---

## Étape 11 — Scalabilité et rolling update

**Objectif :** Pratiquer le scaling horizontal et les mises à jour sans interruption.

### 11.1 — Scaling du frontend de vote

L'affluence augmente — il faut plus de replicas sur le frontend.

Scaler le Deployment `vote-ui` à 5 replicas et observer :
```bash
# Commande à trouver : kubectl scale ...
kubectl get pods -n voting -l app=vote-ui -w
```

### 11.2 — Rolling update du backend de vote

Mettre à jour le Deployment `vote` :
- Changer l'annotation `change-cause` en `"test rolling update"`
- Changer `OPTION_A` dans le ConfigMap en `"Chiens"` et `OPTION_B` en `"Chats"`

> **Attention :** Modifier un ConfigMap ne redémarre pas automatiquement les pods. Comment forcer le rechargement ?

Observer le rolling update avec 0 downtime :
```bash
kubectl rollout status deployment/vote -n voting
kubectl rollout history deployment/vote -n voting
```

> **Question :** Le backend `vote` a été mis à jour, mais pas `vote-ui`. Les utilisateurs voient-ils encore l'ancienne valeur ? Pourquoi ?

### 11.3 — Rollback

Revenir à la configuration précédente.

```bash
kubectl rollout undo deployment/vote -n voting
kubectl rollout status deployment/vote -n voting
```

---

## Étape 12 — DaemonSet de collecte de métriques

**Objectif :** Déployer un agent sur chaque nœud worker pour collecter des métriques locales.

Créer `10-daemonset/metrics-agent.yaml` :

**DaemonSet** `metrics-agent` dans le namespace `voting` :
- Image `busybox:1.36`
- Commande : `sh -c "while true; do echo \"[$(date)] Node=$NODE_NAME — Pods=$(ls /var/log/pods/ 2>/dev/null | wc -l)\"; sleep 30; done"`
- Variable `NODE_NAME` via Downward API (spec.nodeName)
- Volume `hostPath` : `/var/log/pods` du nœud monté dans `/var/log/pods` du container
- **nodeSelector** : `kubernetes.io/os: linux`
- **Tolérations** : aucune (le DaemonSet ne doit pas tourner sur le control-plane)

**Validation :**
```bash
kubectl get daemonset metrics-agent -n voting
kubectl get pods -n voting -l app=metrics-agent -o wide
kubectl logs -n voting -l app=metrics-agent
```

> **Question :** Combien de pods metrics-agent sont créés ? Pourquoi le control-plane est-il exclu sans qu'on le configure explicitement ?

---

## Étape 13 — Job de rapport de votes

**Objectif :** Exécuter une tâche ponctuelle d'export des résultats.

Créer `11-jobs/report.yaml` :

**Job** `vote-report` dans `voting` :
- `completions: 3` (3 rapports à générer)
- `parallelism: 2` (2 en parallèle)
- `backoffLimit: 2`
- Image `postgres:15-alpine`
- Commande :
  ```sh
  psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB \
    -c "SELECT vote, COUNT(id) as total FROM votes GROUP BY vote;" \
  && echo "Rapport généré à $(date)"
  ```
- Variables d'environnement depuis ConfigMap et Secret
- Variable d'environnement `PGPASSWORD` = valeur de `POSTGRES_PASSWORD` (requis par psql)
- `restartPolicy: Never`

**CronJob** `vote-stats` :
- Planification : toutes les minutes (`*/1 * * * *`)
- Même image et commande que le Job
- `successfulJobsHistoryLimit: 3`
- `failedJobsHistoryLimit: 1`
- `concurrencyPolicy: Forbid` (ne pas lancer si le précédent tourne encore)

**Validation :**
```bash
kubectl get jobs -n voting
kubectl logs -n voting -l job-name=vote-report
kubectl get cronjob vote-stats -n voting
kubectl get jobs -n voting -w
```

---

## Étape 14 — RBAC

**Objectif :** Contrôler les accès selon les rôles de l'équipe.

### 12.1 — ServiceAccount pour le worker

Le worker n'a pas besoin d'accéder à l'API Kubernetes — il ne communique qu'avec Redis et PostgreSQL. Désactiver le montage automatique du token :

Créer `12-rbac/serviceaccount.yaml` :
- Un **ServiceAccount** `voting-worker-sa` avec `automountServiceAccountToken: false`
- Mettre à jour le Deployment `worker` pour utiliser ce ServiceAccount

### 12.2 — Utilisateur développeur (lecture seule)

Créer un certificat X.509 pour `dev-alice` avec le groupe `dev-team` :

```bash
openssl genrsa -out alice.key 2048
openssl req -new -key alice.key -subj "/CN=dev-alice/O=dev-team" -out alice.csr
```

Soumettre le CSR à Kubernetes, l'approuver, créer le contexte kubectl.

Créer `12-rbac/alice-rbac.yaml` :
- **Role** `voting-reader` : `get/list/watch` sur pods, services, deployments, configmaps, endpoints dans `voting`
- **RoleBinding** : `dev-alice` → `voting-reader`

**Validation :**
```bash
kubectl auth can-i list pods -n voting --as dev-alice          # yes
kubectl auth can-i delete pods -n voting --as dev-alice         # no
kubectl auth can-i list secrets -n voting --as dev-alice        # no
kubectl auth can-i list pods -n default --as dev-alice          # no

kubectl --context=alice-ctx get pods -n voting
kubectl --context=alice-ctx delete pod <nom-pod> -n voting      # Forbidden
kubectl --context=alice-ctx get secret voting-secrets -n voting # Forbidden
```

### 12.3 — Groupe ops (déploiement)

Créer `12-rbac/ops-rbac.yaml` :
- **ClusterRole** `voting-deployer` : `get/list/watch/create/update/patch` sur deployments, replicasets, pods dans tous les namespaces
- **ClusterRoleBinding** : groupe `ops-team` → `voting-deployer`

Tester :
```bash
kubectl auth can-i update deployments -n voting --as-group=ops-team --as=ops-bob  # yes
kubectl auth can-i delete namespaces --as-group=ops-team --as=ops-bob              # no
```

---

## Récapitulatif — Structure attendue

```
voting-app/
├── 01-namespace/
│   └── namespace.yaml          # Namespace + ResourceQuota + LimitRange
├── 02-config/
│   ├── configmap.yaml           # voting-config
│   └── secret.yaml              # voting-secrets
├── 03-database/
│   └── postgres.yaml            # Service + StatefulSet + PVC
├── 04-redis/
│   └── redis.yaml               # Service + Deployment
├── 05-worker/
│   └── worker.yaml              # Deployment (no port) — mohamed1780/worker
├── 06-vote/
│   ├── vote.yaml                # Deployment + ClusterIP — mohamed1780/vote (backend)
│   └── vote-ui.yaml             # Deployment + NodePort :31000 — mohamed1780/vote-ui (frontend)
├── 07-result/
│   ├── result.yaml              # Deployment + ClusterIP — mohamed1780/result (backend)
│   └── result-ui.yaml           # Deployment + NodePort :31001 — mohamed1780/result-ui (frontend)
├── 12-daemonset/
│   └── metrics-agent.yaml       # DaemonSet hostPath + Downward API
├── 13-jobs/
│   └── report.yaml              # Job + CronJob
└── 14-rbac/
    ├── serviceaccount.yaml      # SA worker sans token
    ├── alice-rbac.yaml          # Role + RoleBinding dev-alice
    └── ops-rbac.yaml            # ClusterRole + ClusterRoleBinding ops-team
```

---

## Questions de synthèse

1. Le worker n'expose aucun port. Comment communique-t-il avec Redis et PostgreSQL ?
2. Pourquoi PostgreSQL est un **StatefulSet** et Redis un **Deployment** dans cette application ?
3. Quelle est la différence de rôle entre `vote` (ClusterIP) et `vote-ui` (NodePort) ? Pourquoi ne pas exposer directement le backend ?
4. `vote-ui` contacte `http://vote:8080` pour soumettre un vote. Ce DNS est-il résolu par le DNS du cluster ou par un DNS externe ?
5. Vous avez modifié le ConfigMap `voting-config`. Les pods `vote` ont-ils pris en compte le changement ? Pourquoi ? Que faut-il faire ?
6. Avec `maxUnavailable: 0` sur le Deployment `vote`, que garantit-on pendant le rolling update ?
7. Le worker tourne avec `automountServiceAccountToken: false`. Dans quel cas aurait-on besoin de mettre `true` ?
8. Le DaemonSet ne tourne pas sur le control-plane. Quel mécanisme K8s l'en empêche sans configuration explicite de votre part ?
9. `dev-alice` peut lister les pods dans `voting`. Peut-elle les lister dans `default` ? Que faudrait-il pour qu'elle le puisse ?
10. Le Job `vote-report` a `parallelism: 2` et `completions: 3`. Dessinez la séquence d'exécution des pods.

---

## Commandes de référence

```bash
# Appliquer tout le projet dans l'ordre
kubectl apply -f 01-namespace/
kubectl apply -f 02-config/
kubectl apply -f 03-database/
kubectl apply -f 04-redis/
kubectl apply -f 05-worker/
kubectl apply -f 06-vote/    # contient vote.yaml (backend) + vote-ui.yaml (frontend)
kubectl apply -f 07-result/  # contient result.yaml (backend) + result-ui.yaml (frontend)

# Vérifier l'état global
kubectl get all -n voting

# Suivre les événements en temps réel
kubectl get events -n voting --sort-by='.lastTimestamp' -w

# Debug inter-services
kubectl run debug -n voting --image=busybox:1.36 --rm -it -- sh

# Voir les logs de tous les pods d'un composant
kubectl logs -n voting -l app=worker -f

# Vérifier les ressources consommées
kubectl top pods -n voting
```
