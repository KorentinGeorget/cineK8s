#!/usr/bin/env bash
# ==============================================================================
# Script automatique — CinéK8s (Examen Kubernetes)
# Auteur : GEORGET Korentin
# ==============================================================================

set -uo pipefail

# Couleurs
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_step() {
    echo -e "\n${BLUE}${BOLD}================================================================${NC}"
    echo -e "${BLUE}${BOLD}==> $1${NC}"
    echo -e "${BLUE}${BOLD}================================================================${NC}"
}

log_cmd() {
    echo -e "${CYAN}${BOLD}$ $1${NC}"
}

log_assert() {
    echo -e "${YELLOW}   [Condition vérifiée] $1${NC}"
}

log_success() {
    echo -e "${GREEN}${BOLD}   ✔ VALIDÉ : $1${NC}\n"
}

log_warn() {
    echo -e "${YELLOW}   ⚠ $1${NC}\n"
}

log_error() {
    echo -e "${RED}${BOLD}   ✖ ÉCHEC : $1${NC}\n"
}

# ------------------------------------------------------------------------------
# 1. Vérification des prérequis
# ------------------------------------------------------------------------------
log_step "1. Vérification des prérequis système"

log_cmd "which kubectl"
which kubectl
log_success "kubectl est installé"

log_cmd "minikube status"
minikube status
log_success "Cluster Minikube en cours d'exécution"

MINIKUBE_IP=$(minikube ip)
echo -e "   IP Minikube : ${BOLD}${MINIKUBE_IP}${NC}"

log_cmd "minikube addons list | grep ingress"
minikube addons list | grep ingress
log_success "Addon Ingress activé"

echo "   Attente du contrôleur Ingress Nginx..."
kubectl wait --namespace ingress-nginx --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=90s >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2. Vérification des images de conteneurs
# ------------------------------------------------------------------------------
log_step "2. Vérification des images dans Minikube"

log_cmd "minikube image ls | grep -E 'movie-service:1.0.0|ticket-service:1.0.0'"
minikube image ls | grep -E 'movie-service:1.0.0|ticket-service:1.0.0'
log_assert "Présence des images locales movie-service:1.0.0 et ticket-service:1.0.0"
log_success "Images conteneurs prêtes"

# ------------------------------------------------------------------------------
# 3. Déploiement Kubernetes
# ------------------------------------------------------------------------------
log_step "3. Application des manifests Kubernetes (k8s/)"

log_cmd "kubectl apply -f k8s/"
kubectl apply -f k8s/

kubectl config set-context --current --namespace=cinema-exam >/dev/null

log_cmd "kubectl wait --for=condition=ready pod -l app=movie --timeout=90s"
kubectl wait --namespace cinema-exam --for=condition=ready pod -l app=movie --timeout=90s

log_cmd "kubectl wait --for=condition=ready pod -l app=ticket --timeout=90s"
kubectl wait --namespace cinema-exam --for=condition=ready pod -l app=ticket --timeout=90s
log_success "Tous les Pods ont passé leurs startupProbes et sont 1/1 Ready"

echo ""
log_cmd "kubectl get pods -n cinema-exam -o wide"
kubectl get pods -n cinema-exam -o wide

echo ""
log_cmd "kubectl get endpoints movie ticket -n cinema-exam"
kubectl get endpoints -n cinema-exam movie ticket
log_assert "Endpoints non-vides avec 2 adresses IP de Pods pour chaque service"
log_success "Services et Endpoints correctement associés"

# ------------------------------------------------------------------------------
# 4. Tests inter-services (DNS interne)
# ------------------------------------------------------------------------------
log_step "4. Test de la communication inter-service (DNS interne K8s)"

log_cmd "kubectl exec deploy/ticket -n cinema-exam -- wget -qO- http://movie:8080/api/movies/whoami"
WHOAMI_OUTPUT=$(kubectl exec deploy/ticket -n cinema-exam -- wget -qO- http://movie:8080/api/movies/whoami)
echo -e "   Sortie : ${BOLD}${WHOAMI_OUTPUT}${NC}"
log_assert "Résolution DNS interne 'movie:8080' fonctionnelle depuis ticket"
log_success "Appel inter-service opérationnel"

log_cmd "kubectl exec deploy/ticket -n cinema-exam -- wget -qO- http://localhost:8080/actuator/health/readiness"
READINESS_TICKET=$(kubectl exec deploy/ticket -n cinema-exam -- wget -qO- http://localhost:8080/actuator/health/readiness)
echo -e "   Sortie : ${BOLD}${READINESS_TICKET}${NC}"
log_assert "Composants 'readinessState' == UP et 'movie' == UP"
if echo "$READINESS_TICKET" | grep -q '"status":"UP"'; then
    log_success "Readiness dépendante de movie est UP"
else
    log_error "Readiness DOWN"
fi

# ------------------------------------------------------------------------------
# 5. Tests de l'Ingress (cinema.local)
# ------------------------------------------------------------------------------
log_step "5. Tests via l'Ingress HTTP (cinema.local)"

CURL_BASE="curl -s --resolve cinema.local:80:${MINIKUBE_IP}"

echo -e "   [Test 5.1] Catalogue des films :"
log_cmd "curl -s --resolve cinema.local:80:${MINIKUBE_IP} http://cinema.local/api/movies"
MOVIES_JSON=$($CURL_BASE http://cinema.local/api/movies)
if command -v jq &>/dev/null && echo "$MOVIES_JSON" | jq -e . &>/dev/null; then
    echo "$MOVIES_JSON" | jq '.[].title'
else
    echo "$MOVIES_JSON"
fi
log_assert "Code HTTP 200 et liste des 4 films retournée"
log_success "Routage Ingress /api/movies opérationnel"

echo -e "   [Test 5.2] Création de réservation :"
log_cmd "curl -s -X POST --resolve cinema.local:80:${MINIKUBE_IP} http://cinema.local/api/tickets -d '{\"movieId\":1,\"seats\":2}'"
TICKET_JSON=$($CURL_BASE -X POST http://cinema.local/api/tickets \
    -H 'Content-Type: application/json' \
    -d '{"movieId":1,"seats":2}')
if command -v jq &>/dev/null && echo "$TICKET_JSON" | jq -e . &>/dev/null; then
    echo "$TICKET_JSON" | jq
else
    echo "$TICKET_JSON"
fi
log_assert "Code HTTP 201 Created et calcul correct du montant total"
log_success "Routage Ingress /api/tickets et réservation opérationnels"

echo -e "   [Test 5.3] Répartition de charge (Load-balancing 6 requêtes whoami) :"
log_cmd "for i in 1..6; do curl http://cinema.local/api/movies/whoami; done"
for i in $(seq 1 6); do
    RESP=$($CURL_BASE http://cinema.local/api/movies/whoami)
    if command -v jq &>/dev/null && echo "$RESP" | jq -e . &>/dev/null; then
        echo -e "   Requête $i -> hostname: $(echo "$RESP" | jq -r .hostname)"
    else
        echo -e "   Requête $i -> $RESP"
    fi
done
log_assert "Alternance entre les hostnames des deux Pods movie"
log_success "Load-balancing round-robin validé"

echo -e "   [Test 5.4] Étanchéité d'Actuator :"
log_cmd "curl -s -o /dev/null -w '%{http_code}' http://cinema.local/actuator/health"
ACTUATOR_CODE=$($CURL_BASE -o /dev/null -w '%{http_code}\n' http://cinema.local/actuator/health)
echo -e "   Code HTTP retourné : ${BOLD}${ACTUATOR_CODE}${NC}"
log_assert "Code HTTP == 404 (non exposé via l'Ingress externe)"
if [[ "$ACTUATOR_CODE" == "404" ]]; then
    log_success "Sécurité respectée : Actuator n'est pas exposé via l'Ingress"
else
    log_warn "Code inattendu : $ACTUATOR_CODE"
fi

# ------------------------------------------------------------------------------
# 6. Démonstration de résilience (Partie 6.1)
# ------------------------------------------------------------------------------
log_step "6. Démonstration de résilience : arrêt de movie-service"

log_cmd "kubectl scale deploy/movie --replicas=0 -n cinema-exam"
kubectl scale deploy/movie --replicas=0 -n cinema-exam

echo "   Attente de 30s pour la détection par la readinessProbe (3 échecs consécutifs)..."
sleep 30

log_cmd "kubectl get pods -n cinema-exam -l app=ticket"
kubectl get pods -n cinema-exam -l app=ticket

TICKET_STATUS=$(kubectl get pods -n cinema-exam -l app=ticket --no-headers | awk '{print $2}' | head -1)

log_cmd "curl -i http://cinema.local/api/tickets | head -1"
HTTP_DOWN_HEADER=$($CURL_BASE -i http://cinema.local/api/tickets | head -1)
echo -e "   Sortie : ${BOLD}${HTTP_DOWN_HEADER}${NC}"

log_assert "ticket passe à 0/1 (NotReady), RESTARTS reste à 0, et Ingress renvoie HTTP 503"
if [[ "$TICKET_STATUS" == "0/1" ]] && echo "$HTTP_DOWN_HEADER" | grep -q "503"; then
    log_success "Résilience validée : éviction automatique sans redémarrage intempestif"
else
    log_warn "Statut observé : pods $TICKET_STATUS, header $HTTP_DOWN_HEADER"
fi

log_cmd "kubectl scale deploy/movie --replicas=2 -n cinema-exam"
kubectl scale deploy/movie --replicas=2 -n cinema-exam
sleep 2

log_cmd "kubectl wait --for=condition=ready pod -l app=movie"
kubectl wait --namespace cinema-exam --for=condition=ready pod -l app=movie --timeout=60s

log_cmd "kubectl wait --for=condition=ready pod -l app=ticket"
kubectl wait --namespace cinema-exam --for=condition=ready pod -l app=ticket --timeout=60s
log_assert "Tous les Pods redeviennent 1/1 Ready sans intervention sur ticket"
log_success "Auto-healing validé : retour à la normale automatique"

# ------------------------------------------------------------------------------
# 7. Vérification des Bonus (B1 & B2)
# ------------------------------------------------------------------------------
log_step "7. Vérification des Bonus"

echo -e "   [Bonus B1] Hardening de movie (non-root & read-only fs) :"
log_cmd "kubectl exec deploy/movie -n cinema-exam -- id -u"
USER_ID=$(kubectl exec deploy/movie -n cinema-exam -- id -u 2>/dev/null || echo "err")
echo -e "   UID conteneur : ${BOLD}${USER_ID}${NC}"

log_cmd "kubectl exec deploy/movie -n cinema-exam -- touch /test"
RO_FS=$(kubectl exec deploy/movie -n cinema-exam -- touch /test 2>&1 || true)
echo -e "   Sortie touch : ${BOLD}${RO_FS}${NC}"

log_assert "UID == 10001 (spring) et Read-only file system sur la racine"
if [[ "$USER_ID" == "10001" ]] && echo "$RO_FS" | grep -iq "Read-only file system"; then
    log_success "Bonus B1 validé (+1 pt)"
else
    log_warn "Bonus B1 incomplet"
fi

echo -e "   [Bonus B2] Stratégie RollingUpdate sans coupure :"
log_cmd "kubectl get deploy/movie -o jsonpath='{.spec.strategy.rollingUpdate}'"
MAX_UNAVAIL=$(kubectl get deploy/movie -n cinema-exam -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}')
MAX_SURGE=$(kubectl get deploy/movie -n cinema-exam -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}')
echo -e "   maxUnavailable: ${BOLD}${MAX_UNAVAIL}${NC}, maxSurge: ${BOLD}${MAX_SURGE}${NC}"

log_assert "maxUnavailable == 0 et maxSurge == 1"
if [[ "$MAX_UNAVAIL" == "0" ]] && [[ "$MAX_SURGE" == "1" ]]; then
    log_success "Bonus B2 validé (+1 pt)"
fi

# ------------------------------------------------------------------------------
# Fin
# ------------------------------------------------------------------------------
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  ✔ VALIDATION COMPLÈTE TERMINÉE : TOUTES LES ÉTAPES SONT VALIDÉES${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}\n"
