# Examen CinéK8s — GEORGET Korentin

## Partie 1 — Comprendre le code

**Q1.1** — 
- **Propriété Spring** : `movie.url` (injectée via `@Value("${movie.url}") String movieUrl` dans le constructeur de `MovieClient`).
- **Variable d'environnement** : `MOVIE_URL`. Le mécanisme de *relaxed binding* de Spring Boot convertit automatiquement les noms de propriétés en majuscules et remplace les séparateurs (`.` et `-`) par des underscores (`_`).

**Q1.2** — Codes HTTP renvoyés par `ticket-service` :
- (a) Le film demandé n'existe pas : **`422 Unprocessable Entity`** (`MovieClient` renvoie `Optional.empty()`, ce qui lève une `ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY)`).
- (b) Il reste moins de places que demandé : **`409 Conflict`** (`movie.seats() < request.seats()`, ce qui lève une `ResponseStatusException(HttpStatus.CONFLICT)`).
- (c) `movie-service` ne répond pas du tout : **`503 Service Unavailable`** (l'appel `RestClient` lève une `ResourceAccessException`, interceptée et transformée en `ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE)`).

**Q1.3** — 
Ligne complétée dans `ticket-service/src/main/resources/application.yaml` :
```yaml
      group:
        readiness:
          include: readinessState,movie
```
*Explication* : La **readiness** probe détermine si le Pod est apte à recevoir et traiter du trafic client ; si sa dépendance directe (`movie-service`) est indisponible, le Pod ne peut pas honorer les réservations et doit être retiré temporairement des Endpoints du Service sans être détruit. À l'inverse, si cette dépendance était dans la **liveness** probe, la chute de `movie-service` ferait échouer la liveness de `ticket-service`, poussant le kubelet à tuer et redémarrer en boucle des conteneurs sains (*restart storm*), ce qui n'a aucun sens car redémarrer `ticket-service` ne résout pas la panne de `movie-service`.

**Q1.4** — 

| Endpoint | Probe(s) Kubernetes qui l'utilisent | Conséquence d'un **échec** de la probe |
|----------|-------------------------------------|----------------------------------------|
| `/actuator/health/liveness` | `startupProbe` et `livenessProbe` | Pour `startupProbe` : si le nombre d'échecs dépasse `failureThreshold`, le conteneur est tué et redémarré par le kubelet. Pour `livenessProbe` : dès que le seuil d'échec est atteint, le kubelet tue et redémarre le conteneur selon la politique de redémarrage. |
| `/actuator/health/readiness` | `readinessProbe` | Le Pod passe à l'état `NotReady` (ex. `0/1`) et son adresse IP est immédiatement retirée des Endpoints / EndpointSlices du Service (aucun trafic ne lui est envoyé), mais le conteneur n'est **pas** redémarré. |

*Rôle de `server.shutdown: graceful`* : Lors d'un rolling update ou d'un arrêt de Pod, il permet à Tomcat de refuser les nouvelles connexions entrantes tout en laissant un délai de grâce pour achever le traitement des requêtes HTTP déjà en cours, évitant ainsi les interruptions brutales (erreurs 502 ou connexions réinitialisées côté client).

---

## Partie 2 — Tester en local, sans Kubernetes

### 2.1 — Sorties des commandes demandées

Réservation via `ticket-service` :
```bash
$ curl -s -X POST localhost:8082/api/tickets \
  -H 'Content-Type: application/json' \
  -d '{"movieId":2,"seats":3}' | jq
```
```json
{
  "id": 2,
  "movieId": 2,
  "movieTitle": "Le Seigneur des Pods",
  "seats": 3,
  "total": 36.00,
  "createdAt": "2026-10-08T09:05:06.303531042Z"
}
```

Readiness de `ticket-service` avec `movie-service` actif :
```bash
$ curl -s localhost:8082/actuator/health/readiness | jq
```
```json
{
  "status": "UP",
  "components": {
    "movie": {
      "status": "UP"
    },
    "readinessState": {
      "status": "UP"
    }
  }
}
```

### 2.2 — Coupure de `movie-service`

Sorties après arrêt du processus `movie-service` :
```bash
$ curl -s localhost:8082/actuator/health/readiness | jq
```
```json
{
  "status": "DOWN",
  "components": {
    "movie": {
      "status": "DOWN",
      "details": {
        "error": "I/O error on GET request for \"http://localhost:8080/actuator/health/liveness\": null"
      }
    },
    "readinessState": {
      "status": "UP"
    }
  }
}
```

```bash
$ curl -s localhost:8082/actuator/health/liveness | jq .status
"UP"

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8082/api/tickets \
  -H 'Content-Type: application/json' -d '{"movieId":2,"seats":3}'
503
```

**Q2.1** — On utilise `SERVER_PORT=8082` pour respecter le principe de configuration externalisée (Twelve-Factor App) sans altérer les fichiers de configuration versionnés dans le dépôt Git. Le mécanisme Spring Boot qui rend cela possible est la hiérarchie des `PropertySource` combinée au *relaxed binding*, où les variables d'environnement système ont une priorité supérieure à celle des fichiers `application.yaml` / `application.properties`.

**Q2.2** — C'est exactement le comportement attendu car le processus `ticket-service` lui-même est sain (JVM en cours d'exécution, mémoire intacte, pas de blocage interne), donc la liveness doit rester `UP` pour éviter un redémarrage inutile. En revanche, sa dépendance externe étant indisponible, il est temporairement incapable de traiter des réservations, ce qui doit se traduire par une readiness `DOWN` afin d'isoler le service du flux de requêtes.

---

## Partie 3 — Conteneuriser

**Q3.1** — On copie `pom.xml` avant `src/` pour tirer parti du système de cache en couches (layers) de Docker. Le téléchargement des dépendances (`mvn dependency:go-offline`) est long ; tant que `pom.xml` ne change pas, cette couche est réutilisée depuis le cache. Lorsqu'on ne modifie qu'une ligne de code Java dans `src/`, seules les couches à partir de `COPY src ./src` sont réexécutées, ce qui réduit le temps de compilation à quelques secondes.

**Q3.2** — `-XX:MaxRAMPercentage=75` est préférable car il s'adapte dynamiquement à la limite de mémoire fixée par le cgroup du conteneur (ex. définie par Kubernetes via `resources.limits.memory`). Une valeur statique comme `-Xmx512m` est rigide : si la limite du conteneur passe à 1 Go, la JVM reste bridée ; si la limite passe à 256 Mo, la JVM dépasse la limite du conteneur et est tuée par le noyau (`OOMKilled`). De plus, le ratio de 75 % laisse 25 % de marge pour la mémoire non-heap (Metaspace, stacks des threads, code cache, buffers natifs).

**Q3.3** — Dans Kubernetes, les Pods démarrent de façon asynchrone et indépendante. Si les Pods `ticket` démarrent avant `movie`, leur `readinessProbe` échoue lors de la vérification de l'indicateur `movie` ; les Pods `ticket` restent temporairement dans l'état `0/1 (NotReady)` et ne reçoivent aucun trafic via leur Service. Dès que les Pods `movie` démarrent et que le Service `movie` devient joignable via le DNS interne, la readiness passe à `UP`, et les Pods `ticket` deviennent `1/1 (Ready)` sans nécessiter aucun redémarrage.

---

## Partie 4 — Déployer sur Minikube

### Sorties de vérification demandées

État des Pods :
```bash
$ kubectl get pods
NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-trd4g    1/1     Running   0          32s
movie-59684459f4-x8qsx    1/1     Running   0          32s
ticket-66d95c98b6-ct7wp   1/1     Running   0          32s
ticket-66d95c98b6-vc2xx   1/1     Running   0          32s
```

Endpoints des Services :
```bash
$ kubectl get endpoints movie ticket
NAME     ENDPOINTS                           AGE
movie    10.244.0.53:8080,10.244.0.54:8080   73s
ticket   10.244.0.55:8080,10.244.0.56:8080   73s
```

Réservation créée via le port-forward :
```bash
$ kubectl port-forward svc/ticket 8082:8080 &
$ curl -s -X POST localhost:8082/api/tickets -H 'Content-Type: application/json' \
  -d '{"movieId":2,"seats":2}' | jq
```
```json
{
  "id": 1,
  "movieId": 2,
  "movieTitle": "Le Seigneur des Pods",
  "seats": 2,
  "total": 24.00,
  "createdAt": "2026-10-08T09:13:05.159105201Z"
}
```

Appels inter-services vérifiés :
```bash
$ kubectl exec deploy/ticket -- wget -qO- http://movie:8080/api/movies/whoami
{"environment":"kubernetes","hostname":"movie-59684459f4-x8qsx"}

$ kubectl exec deploy/ticket -- wget -qO- http://localhost:8080/actuator/health/readiness
{"status":"UP","components":{"movie":{"status":"UP"},"readinessState":{"status":"UP"}}}
```

**Q4.1** — `kubectl apply -f k8s/` traite les manifests par ordre alphabétique (lexicographique) des fichiers. Les préfixes (`00-`, `10-`, `20-`, `30-`, `40-`) permettent de structurer et d'assurer l'ordre de création des dépendances : le Namespace d'abord (`00-`), puis les ConfigMaps (`10-`), le service indépendant `movie` (`20-`), le service dépendant `ticket` (`30-`), et enfin l'Ingress (`40-`).

**Q4.2** — La probe responsable est la `startupProbe`. Ce n'est pas une anomalie : la JVM et Spring Boot prennent entre 10 et 30 secondes pour initialiser le contexte applicatif et démarrer le serveur Tomcat. La `startupProbe` désactive l'exécution des liveness et readiness probes durant cette phase initiale, évitant que la liveness probe ne tue prématurément le conteneur avant la fin de son démarrage.

**Q4.3** — Avec `imagePullPolicy: Always`, le kubelet tenterait de contacter systématiquement le registre distant Docker Hub (`docker.io/library/...`) pour télécharger l'image à chaque instanciation de Pod. Comme nos images sont uniquement construites et chargées en local sur le nœud Minikube et ne sont pas publiées sur un registre externe distant, les Pods échoueraient avec l'erreur `ErrImagePull` puis `ImagePullBackOff`.

---

## Partie 5 — Exposer avec un Ingress

Sorties de test :
```bash
# Titres
$ curl -s http://cinema.local/api/movies | jq '.[].title'
"Pod Fiction"
"Le Seigneur des Pods"
"Docker Wars"
"Rollback to the Future"

# Réservation
$ curl -s -X POST http://cinema.local/api/tickets -H 'Content-Type: application/json' \
  -d '{"movieId":3,"seats":10}' | jq
{
  "id": 1,
  "movieId": 3,
  "movieTitle": "Docker Wars",
  "seats": 10,
  "total": 90.00,
  "createdAt": "2026-10-08T09:13:26.750729822Z"
}

# Load-balancing (whoami)
$ for i in $(seq 1 6); do curl -s http://cinema.local/api/movies/whoami | jq -r .hostname; done
movie-59684459f4-x8qsx
movie-59684459f4-trd4g
movie-59684459f4-trd4g
movie-59684459f4-trd4g
movie-59684459f4-x8qsx
movie-59684459f4-x8qsx

# Actuator health
$ curl -s -o /dev/null -w '%{http_code}\n' http://cinema.local/actuator/health
404
```

**Q5.1** — Deux Pods `movie` distincts ont répondu en alternance. C'est le `Service` Kubernetes `movie` (associé à l'Ingress controller) qui assure la répartition de charge (load-balancing de niveau 4/7) entre les adresses IP des Pods cibles inscrits dans ses Endpoints.

**Q5.2** — Avec `pathType: Exact` sur `/api/movies`, seule la route exacte `/api/movies` matcherait la règle de l'Ingress. Un appel sur une sous-ressource telle que `GET /api/movies/1` ou `/api/movies/whoami` ne correspondrait à aucune règle de routage et renverrait un code d'erreur HTTP **`404 Not Found`**.

**Q5.3** — On obtient le code HTTP **`404 Not Found`**. C'est un comportement tout à fait souhaitable : les endpoints Actuator exposent des métriques d'infrastructure et des détails techniques sensibles qui doivent rester strictement réservés au réseau interne du cluster (pour les probes kubelet et le scraping de monitoring) et ne doivent jamais être rendus accessibles au public via l'Ingress externe.

---

## Partie 6 — Casser pour comprendre

### 6.1 — Le service `movie` disparaît

**Prédictions avant exécution :**
- (a) `READY` et `RESTARTS` des Pods `ticket` après 30 s : `READY: 0/1`, `RESTARTS: 0`
- (b) Contenu de `kubectl get endpoints ticket` : Vide / aucun endpoint
- (c) Code HTTP de `GET http://cinema.local/api/tickets` : `503 Service Temporarily Unavailable`
- (d) Statut de la **liveness** de `ticket` : `UP`

**Observations réelles :**
```bash
$ kubectl scale deploy/movie --replicas=0
$ sleep 30
$ kubectl get pods
NAME                      READY   STATUS    RESTARTS   AGE
ticket-66d95c98b6-ct7wp   0/1     Running   0          97s
ticket-66d95c98b6-vc2xx   0/1     Running   0          97s

$ kubectl get endpoints ticket
NAME     ENDPOINTS   AGE
ticket               2m18s

$ curl -si http://cinema.local/api/tickets | head -1
HTTP/1.1 503 Service Temporarily Unavailable
```

Après rétablissement (`kubectl scale deploy/movie --replicas=2`) :
```bash
NAME                      READY   STATUS    RESTARTS   AGE
movie-59684459f4-hzbl8    1/1     Running   0          15s
movie-59684459f4-m6fv9    1/1     Running   0          15s
ticket-66d95c98b6-ct7wp   1/1     Running   0          113s
ticket-66d95c98b6-vc2xx   1/1     Running   0          113s
```

**Q6.1** — 
Déroulement en 4 étapes entre l'arrêt de `movie` et le code 503 :
1. **Échec de la readiness probe** : Suite à la disparition des Pods `movie`, le composant `MovieHealthIndicator` de `ticket-service` échoue à contacter `http://movie:8080/actuator/health/liveness`. L'endpoint `/actuator/health/readiness` bascule à `DOWN`. Après 3 échecs consécutifs (`failureThreshold: 3`), le kubelet marque les conteneurs `ticket` comme `NotReady`.
2. **Éviction des Endpoints** : Le contrôleur d'endpoints du plan de contrôle Kubernetes détecte que les Pods `ticket` ne sont plus prêts et supprime immédiatement leurs adresses IP des Endpoints du Service `ticket`.
3. **Synchronisation de l'Ingress** : Le contrôleur Ingress Nginx met à jour dynamiquement sa table amont (upstream) et constate que le backend `ticket` ne possède plus aucun serveur disponible.
4. **Renvoi de l'erreur 503** : Toute requête entrante sur `http://cinema.local/api/tickets` aboutit sur un upstream sans backend actif dans Nginx, qui renvoie directement le code HTTP `503 Service Temporarily Unavailable`.

*Pourquoi `RESTARTS` est resté à 0* : La `livenessProbe` surveille `/actuator/health/liveness`, qui n'inclut pas le bean de santé `movie`. Le contexte local de l'application étant parfaitement opérationnel, la liveness est restée `UP`, donc le kubelet n'a déclenché aucun redémarrage.

---

### 6.2 — Mission dépannage (`broken/ticket-debug.yaml`)

| # | Statut observé | Commande de diagnostic | Cause exacte | Correction apportée |
|---|----------------|------------------------|--------------|---------------------|
| 1 | `ErrImagePull` / `ImagePullBackOff` | `kubectl describe pod -l app=ticket-debug` (section Events) | `imagePullPolicy: Always` force le kubelet à interroger le registre distant Docker Hub (`docker.io/library/ticket-service:1.0.0`), où l'image n'existe pas, au lieu d'utiliser l'image présente localement. | Remplacer `imagePullPolicy: Always` par `imagePullPolicy: IfNotPresent`. |
| 2 | `CreateContainerConfigError` | `kubectl describe pod -l app=ticket-debug` (section Events) | Erreur `configmap "ticket-configmap" not found` : le Pod référence une ConfigMap inexistante (`ticket-configmap`), alors que la ressource s'appelle `ticket-config`. | Modifier `configMapRef.name` de `ticket-configmap` à `ticket-config`. |
| 3 | `Running` mais bloqué à `0/1` indéfiniment | `kubectl describe pod -l app=ticket-debug` (section Events) | Erreur `Readiness probe failed: connect: connection refused` : la probe interroge le port `8081`, alors que Spring Boot écoute sur le port `8080`. | Modifier le port de la `readinessProbe` de `8081` à `8080` (ou le nom de port `http`). |

Après correction des 3 erreurs, le Pod est passé à `1/1 Running` avec succès :
```
NAME                           READY   STATUS    RESTARTS   AGE
ticket-debug-56f4f5848-jb5qh   1/1     Running   0          14s
```

---

### 6.3 — Changer la configuration sans rebuild

```bash
$ kubectl apply -f k8s/10-config.yaml
configmap/movie-config configured

$ curl -s http://cinema.local/api/movies/whoami
{"environment":"kubernetes","hostname":"movie-59684459f4-hzbl8"}

$ kubectl rollout restart deploy/movie
$ kubectl rollout status deploy/movie
deployment "movie" successfully rolled out

$ curl -s http://cinema.local/api/movies/whoami
{"environment":"production","hostname":"movie-64cf798b8d-g6bzp"}
```

**Q6.3** — Les variables d'environnement injectées via `envFrom` sont passées aux processus lors de la création initiale du conteneur par le runtime. Modifier une `ConfigMap` met à jour la ressource dans le plan de contrôle Kubernetes (etcd), mais n'a aucun impact dynamique sur les processus Linux déjà en cours d'exécution dans les conteneurs existants. La commande `kubectl rollout restart deploy/movie` a déclenché un rolling update qui a recréé de nouveaux Pods dont l'environnement a été initialisé avec les nouvelles valeurs de la ConfigMap.

---

## Partie 7 — Questions de synthèse

**Q7.1** — Déroulement d'un appel `GET http://movie:8080/api/movies/1` depuis un Pod `ticket` :
1. *Résolution DNS* : La JVM interroge le résolveur DNS interne du cluster (`CoreDNS`) via `/etc/resolv.conf`. CoreDNS résout le nom court `movie` (complété en `movie.cinema-exam.svc.cluster.local`) en l'adresse IP virtuelle du Service (`ClusterIP`).
2. *Routage et Load Balancing* : Lorsque le paquet TCP quitte le conteneur à destination de cette `ClusterIP`, les règles réseau gérées par `kube-proxy` (via iptables ou IPVS sur le nœud) interceptent le paquet et appliquent une translation d'adresse de destination (DNAT) en sélectionnant aléatoirement l'IP d'un Pod `movie` sain listé dans les Endpoints du Service.
3. *Acheminement et exécution* : Le réseau de pods (CNI) achemine le paquet vers l'interface réseau du Pod `movie` sélectionné, où le serveur web Tomcat écoute sur le port `8080` et traite la requête.

**Q7.2** — 
- *Pourquoi le nombre varie* : `TicketController` stocke ses réservations dans une liste en mémoire (`CopyOnWriteArrayList tickets`), propre à l'instance JVM de chaque conteneur. Comme l'Ingress et le Service distribuent le trafic entre les 2 réplicas de `ticket`, chaque appel interroge alternativement l'un ou l'autre Pod, renvoyant uniquement son propre historique local.
- *Si on supprime les Pods `ticket`* : La mémoire étant volatile, la suppression des conteneurs entraîne la perte définitive de toutes les réservations (la liste retombe à 0).
- *Solution architecturale* : Transformer le microservice pour le rendre **stateless** (sans état en mémoire) en déléguant la persistance à une base de données externe et partagée (ex. PostgreSQL, MySQL ou un cluster Redis), éventuellement gérée via des `PersistentVolumes` et un `StatefulSet` ou un service managé.

**Q7.3** — 
- *Constat* : Dès la suppression du Pod, un nouveau Pod `movie` est instantanément créé et démarré par Kubernetes pour maintenir l'état désiré de 2 réplicas.
- *Différence avec un Pod nu (`kind: Pod`)* : Un Pod nu n'est managé par aucun contrôleur. S'il plante, est supprimé ou si son nœud physique tombe en panne, il disparaît définitivement sans jamais être recréé. L'abstraction `Deployment` (qui orchestre un `ReplicaSet`) apporte la boucle de réconciliation (auto-healing), la gestion déclarative du cycle de vie (maintien du quorum de réplicas), ainsi que les mises à jour progressives (rolling updates) et retours arrière (rollbacks) sans coupure.

---

