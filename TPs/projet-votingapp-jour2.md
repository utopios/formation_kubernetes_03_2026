# TP Jour 2 — Sécurisation et Opération de la Voting App

## Contexte

Vous avez déployé la Voting App lors du Jour 1. Elle fonctionne mais elle n'est pas prête pour la production.

Aujourd'hui vous allez :
- **Sécuriser** l'application (NetworkPolicies, SecurityContext, Pod Security Standards)
- **Industrialiser** les déploiements (stratégies de mise à jour, HPA, Helm)
- **Automatiser** la livraison (GitOps avec ArgoCD)

L'application est composée de 5 services :

```
[vote:80] ──redis:6379──> [worker] ──postgres:5432──> [result:80]
```

---

## Partie 1 — NetworkPolicies : Segmentation réseau

### Objectif
Isoler les composants de la Voting App : le worker ne doit parler qu'à redis et postgres, et rien d'autre ne doit accéder directement à postgres.

### Étape 1.1 — Architecture réseau cible

Dessinez (sur papier ou dans un fichier) les flux autorisés :
- Qui peut parler à `postgres:5432` ?
- Qui peut parler à `redis:6379` ?
- Est-ce que `vote` peut directement accéder à `postgres` ?

### Étape 1.2 — Deny-all par défaut

Créez une NetworkPolicy `deny-all` dans le namespace `voting` qui bloque **tout** le trafic entrant et sortant par défaut.

> **Validation** : Après l'application, que se passe-t-il quand vous essayez de voter ?
> ```bash
> kubectl exec -n voting deploy/vote -- curl -s http://redis:6379
> ```

### Étape 1.3 — Autorisation sélective

Créez les NetworkPolicies pour rétablir uniquement les flux nécessaires :

1. `allow-vote-to-redis` : vote peut écrire dans redis
2. `allow-worker-to-redis` : worker peut lire depuis redis
3. `allow-worker-to-postgres` : worker peut écrire dans postgres
4. `allow-result-to-postgres` : result peut lire depuis postgres
5. `allow-dns` : tous les pods peuvent résoudre les noms DNS (port 53 UDP vers kube-dns)

> **Validation** :
> ```bash
> # Ce test DOIT réussir (flux autorisé)
> kubectl exec -n voting deploy/worker -- nc -zv postgres 5432
>
> # Ce test DOIT échouer (flux bloqué)
> kubectl exec -n voting deploy/vote -- nc -zv postgres 5432
> ```

### Questions de réflexion
- Pourquoi bloquer le trafic entre `vote` et `postgres` même si techniquement ça marcherait ?
- Comment tester une NetworkPolicy quand vous n'êtes pas sûr qu'elle est bien appliquée ?
- Quelle est la différence entre un `podSelector: {}` et l'absence de `podSelector` dans une NetworkPolicy ?

---

## Partie 2 — SecurityContext : Durcissement des pods

### Objectif
Appliquer le principe de moindre privilège sur les pods de la Voting App.

### Étape 2.1 — Audit des pods actuels

Avant de modifier quoi que ce soit, auditez les pods existants :

```bash
kubectl get pod -n voting -o yaml | grep -A 20 "securityContext:"
```

> **Questions** :
> - Quel utilisateur exécute les processus dans les conteneurs vote, result, worker ?
> - Les conteneurs ont-ils accès au système de fichiers en écriture ?

### Étape 2.2 — Sécurisation du worker

Le `worker` n'a besoin que de lire redis et écrire dans postgres. Il ne devrait pas :
- Tourner en root
- Pouvoir écrire sur le filesystem principal
- Avoir des capabilities Linux

Ajoutez à la spec du pod `worker` :

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: worker
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

> **Validation** :
> ```bash
> kubectl exec -n voting deploy/worker -- id
> kubectl exec -n voting deploy/worker -- touch /test  # Doit échouer
> ```

> **Attention** : Si le conteneur a besoin d'écrire des fichiers temporaires, ajoutez un `emptyDir` en `tmpfs`.

### Étape 2.3 — Pod Security Standards

Appliquez le niveau `restricted` sur le namespace `voting` en mode `warn` d'abord, puis `enforce` :

```bash
# Mode warn (observe sans bloquer)
kubectl label namespace voting \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest

# Observez les avertissements lors du prochain déploiement
kubectl rollout restart deployment -n voting
```

> **Questions** :
> - Quels pods sont non-conformes au niveau `restricted` ?
> - Quelle est la différence entre `warn` et `enforce` ?
> - Pourquoi est-il déconseillé de passer directement en mode `enforce` sur un namespace existant ?

### Étape 2.4 — Passage en enforce

Une fois que tous les pods sont conformes, passez en mode `enforce` :

```bash
kubectl label namespace voting \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

> **Validation** : Essayez de créer un pod non-conforme dans ce namespace :
> ```bash
> kubectl run test-root --image=nginx --restart=Never -n voting
> # Doit être rejeté avec un message d'erreur explicite
> ```

---

## Partie 3 — Stratégies de déploiement

### Objectif
Déployer une nouvelle version de la Voting App sans interruption de service.

### Étape 3.1 — Rolling Update du composant vote

Le composant `vote` a une nouvelle version (simulez-en une en changeant une variable d'environnement `APP_VERSION`).

Configurez le Deployment `vote` pour un rolling update avec :
- Toujours au moins 1 instance disponible pendant la mise à jour
- Maximum 2 nouvelles instances créées simultanément

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 2
```

> **Validation** : Pendant le rollout, observez les pods en temps réel :
> ```bash
> kubectl rollout status deployment/vote -n voting --watch
> kubectl get pods -n voting -w   # Dans un autre terminal
> ```

> **Question** : Avec `maxUnavailable: 0`, combien de pods vote sont en cours à la fois pendant la mise à jour si vous avez 3 réplicas ?

### Étape 3.2 — Rollback

Simulez un bug : déployez une version avec une image qui n'existe pas (`docker/example-voting-app-vote:v99-broken`).

```bash
kubectl set image deployment/vote vote=docker/example-voting-app-vote:v99-broken -n voting
```

> **Questions** :
> - Que se passe-t-il ? Est-ce que l'application est toujours disponible ?
> - Comment annuler ce déploiement raté ?
> - Quelle commande vous montre l'historique des révisions ?

### Étape 3.3 — Déploiement Canary (optionnel)

Pour tester une nouvelle option de vote auprès d'un sous-ensemble d'utilisateurs :

1. Créez un second Deployment `vote-canary` avec 1 réplica et les nouvelles options `"Tea"/"Coffee"`
2. Ajoutez le label `track: stable` sur `vote` (3 réplicas) et `track: canary` sur `vote-canary` (1 réplica)
3. Le Service existant doit sélectionner les deux (avec un label commun `app: vote`)

> **Question** : Avec 3 réplicas stable + 1 canary, quelle proportion du trafic ira vers la version canary ?

---

## Partie 4 — HPA : Auto-scaling

### Objectif
Configurer le scaling automatique du composant `vote` selon la charge CPU.

### Étape 4.1 — Ressources obligatoires

L'HPA a besoin de `resources.requests` pour calculer l'utilisation. Ajoutez-les au Deployment `vote` si ce n'est pas déjà fait :

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 300m
    memory: 256Mi
```

### Étape 4.2 — Création de l'HPA

Créez un HPA pour le Deployment `vote` :
- Minimum : 2 réplicas
- Maximum : 8 réplicas
- Cible CPU : 60%
- Cible mémoire : 80%

Utilisez l'API `autoscaling/v2`.

> **Validation** :
> ```bash
> kubectl get hpa -n voting
> kubectl describe hpa vote -n voting
> ```
> L'HPA doit afficher des métriques réelles (pas `<unknown>`).

### Étape 4.3 — Test de charge

Générez de la charge pour déclencher le scaling :

```bash
# Dans un terminal : surveiller l'HPA
kubectl get hpa vote -n voting -w

# Dans un autre terminal : générer de la charge
kubectl run load-generator \
  --image=busybox \
  --restart=Never \
  -n voting \
  -- /bin/sh -c "while true; do wget -q -O- http://vote/; done"
```

> **Questions** :
> - Combien de temps s'écoule avant que le scaling up commence ?
> - Après avoir supprimé le générateur de charge, combien de temps avant le scaling down ?
> - Que se passe-t-il si vous fixez `minReplicas: 1` et qu'il n'y a aucune charge ?

### Étape 4.4 — Comportement de scale-down (avancé)

Configurez un `behavior` pour empêcher un scale-down trop agressif :

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300   # Attendre 5 min avant de réduire
    policies:
    - type: Pods
      value: 1
      periodSeconds: 60              # Max -1 pod par minute
```

> **Question** : Pourquoi un scale-down trop rapide est-il dangereux en production ?

---

## Partie 5 — Helm : Packaging de la Voting App

### Objectif
Packager la Voting App en un chart Helm réutilisable pour les environnements dev et prod.

### Étape 5.1 — Inspection du chart fourni

Explorez le chart dans `demos-jour2/06-helm/voting-chart/` :

```bash
helm lint voting-chart
helm template voting-dev voting-chart -f values-dev.yaml --namespace voting-dev | less
```

> **Questions** :
> - Combien de templates le chart contient-il ?
> - Quelle est la différence entre `values.yaml` et `values-dev.yaml` ?
> - Que fait la fonction `include "voting-chart.labels"` dans les templates ?

### Étape 5.2 — Déploiement multi-environnements

Déployez l'application dans deux namespaces différents :

```bash
# Environnement DEV
kubectl create namespace voting-dev
helm install voting-dev ./voting-chart \
  -f values-dev.yaml \
  -n voting-dev

# Environnement PROD (après avoir validé le DEV)
kubectl create namespace voting-prod
helm install voting-prod ./voting-chart \
  -f values-prod.yaml \
  -n voting-prod
```

> **Validation** :
> ```bash
> helm list -A
> kubectl get pods -n voting-dev
> kubectl get pods -n voting-prod
> # Comparez les replicas et les ressources entre les deux environnements
> ```

### Étape 5.3 — Mise à jour des options de vote

Sans modifier les fichiers YAML, changez les options de vote en prod :

```bash
helm upgrade voting-prod ./voting-chart \
  -f values-prod.yaml \
  --set vote.optionA="Kubernetes" \
  --set vote.optionB="Docker Swarm" \
  -n voting-prod
```

> **Questions** :
> - Quelle révision Helm avez-vous maintenant ?
> - Comment vérifier que les options ont bien changé dans le pod ?

### Étape 5.4 — Rollback Helm

Simulez un problème et faites un rollback :

```bash
# "Mauvaise" mise à jour
helm upgrade voting-prod ./voting-chart \
  -f values-prod.yaml \
  --set postgres.image.tag="invalid-tag" \
  -n voting-prod

# Observer l'échec
helm status voting-prod -n voting-prod

# Rollback à la version précédente
helm rollback voting-prod -n voting-prod
```

> **Question** : Quelle différence entre `helm rollback` et `kubectl rollout undo` ?

### Étape 5.5 — Personnaliser le chart (avancé)

Ajoutez un nouveau paramètre au chart : `vote.backgroundColor` (couleur de fond de l'interface de vote), transmis comme variable d'environnement `BACKGROUND_COLOR` au pod.

Modifiez :
1. `values.yaml` : ajouter `backgroundColor: "#4CAF50"` sous `vote:`
2. `templates/vote-deployment.yaml` : ajouter la variable d'environnement
3. Tester avec `helm upgrade`

---

## Partie 6 — ArgoCD : GitOps

### Objectif
Déployer la Voting App via ArgoCD et observer la réconciliation automatique.

### Étape 6.1 — Installation d'ArgoCD

```bash
bash demos-jour2/05-argocd/01-install-argocd.sh
```

Accédez à l'interface : `http://localhost:8080`
- Login : `admin`
- Mot de passe : `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### Étape 6.2 — Déploiement d'une application via ArgoCD

Créez une Application ArgoCD pointant vers un dépôt Git public contenant des manifestes Kubernetes.

> Utilisez le dépôt d'exemple ArgoCD : `https://github.com/argoproj/argocd-example-apps`
> Chemin : `guestbook`

```bash
kubectl apply -f demos-jour2/05-argocd/02-argocd-app.yaml
```

> **Validation** :
> ```bash
> kubectl get application -n argocd
> # Statut attendu : Synced / Healthy
> ```

### Étape 6.3 — Drift detection

Simulez une modification manuelle (qui ne passe pas par Git) :

```bash
# Modification directe — contournement du GitOps
kubectl scale deployment guestbook-ui -n guestbook --replicas=0
```

> **Questions** :
> - Que se passe-t-il dans ArgoCD ? (Observez l'interface ou `kubectl get application -n argocd -w`)
> - Combien de temps avant que ArgoCD détecte et corrige le drift ?
> - Comment désactiver la self-healing pour autoriser des modifications manuelles d'urgence ?

### Étape 6.4 — Principe GitOps (réflexion)

> **Questions de réflexion** :
> 1. Pourquoi est-il problématique de modifier des ressources Kubernetes directement avec `kubectl` dans un environnement GitOps ?
> 2. Comment ArgoCD sait-il qu'une ressource a "divergé" de l'état désiré dans Git ?
> 3. Quelle est la différence entre `Synced` et `Healthy` dans ArgoCD ?
> 4. Dans une vraie équipe, comment organiseriez-vous les dépôts Git pour séparer le code applicatif des manifestes de déploiement ?

---

## Bilan — Questions d'intégration

À la fin de la journée, répondez à ces questions synthèse :

1. **Sécurité défense en profondeur** : Vous avez appliqué NetworkPolicies, SecurityContext, et PSS. Si un attaquant compromise le pod `vote`, que peut-il faire ? Que ne peut-il pas faire ?

2. **Disponibilité** : Vous avez configuré RollingUpdate avec `maxUnavailable: 0` et un HPA. Qu'est-ce qui garantit que l'application reste disponible pendant une mise à jour si le HPA a déjà scalé à 8 réplicas ?

3. **Helm vs ArgoCD** : Helm gère le packaging, ArgoCD gère la réconciliation. Peut-on utiliser les deux ensemble ? Comment ?

4. **Observabilité** : Maintenant que le trafic est segmenté par NetworkPolicies, comment débuggeriez-vous un problème de connectivité entre `worker` et `postgres` ?

---

## Ressources

- [Documentation NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [HPA v2 reference](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Helm Chart best practices](https://helm.sh/docs/chart_best_practices/)
- [ArgoCD documentation](https://argo-cd.readthedocs.io/)
