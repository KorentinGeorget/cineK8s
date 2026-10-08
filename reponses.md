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

