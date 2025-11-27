#!/bin/bash

# SeaweedFS Component Startup Script - Version Améliorée
# Usage: ./start-seaweedfs-components.sh [options]
#
# This script starts SeaweedFS components individually for testing and development

set -euo pipefail

# Configuration avec validation
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.0.0"

# Default configuration avec valeurs raisonnables
MASTER_PORT=${MASTER_PORT:-9333}
VOLUME_PORT=${VOLUME_PORT:-8080}
FILER_PORT=${FILER_PORT:-8888}
S3_PORT=${S3_PORT:-8000}
MQ_PORT=${MQ_PORT:-17777}
METRICS_PORT=${METRICS_PORT:-9324}

# Répertoire de données avec timestamp pour éviter les conflits
DEFAULT_DATA_DIR="/tmp/seaweedfs-$(date +%Y%m%d-%H%M%S)"
DATA_DIR="${WEED_DATA_DIR:-$DEFAULT_DATA_DIR}"
WEED_BINARY="${WEED_BINARY:-weed}"
VERBOSE="${VERBOSE:-1}"

# Component flags
START_MASTER="${START_MASTER:-true}"
START_VOLUME="${START_VOLUME:-true}"
START_FILER="${START_FILER:-true}"
START_S3="${START_S3:-false}"
START_MQ="${START_MQ:-false}"

# Advanced options avec valeurs optimisées
VOLUME_MAX="${VOLUME_MAX:-100}"
VOLUME_SIZE_LIMIT="${VOLUME_SIZE_LIMIT:-1024}" # 1GB par défaut
FILER_MAX_MB="${FILER_MAX_MB:-256}" # 256MB par défaut
USE_RAFT="${USE_RAFT:-true}"
CLEANUP_ON_EXIT="${CLEANUP_ON_EXIT:-true}"
ENABLE_METRICS="${ENABLE_METRICS:-true}"

# Timeouts configurables
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-60}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-30}"

# Colors for output avec support detection terminal
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; BOLD=''; NC=''
fi

# Logging functions avec timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    local color="$2"
    local message="$3"
    echo -e "${color}[$(get_timestamp)] [$level]${NC} $message" >&2
}

log_info() {
    log "INFO" "${GREEN}" "$1"
}

log_warn() {
    log "WARN" "${YELLOW}" "$1"
}

log_error() {
    log "ERROR" "${RED}" "$1"
}

log_step() {
    log "STEP" "${BLUE}" "$1"
}

log_debug() {
    if [[ "${VERBOSE}" -ge 2 ]]; then
        log "DEBUG" "${CYAN}" "$1"
    fi
}

# Validation functions
validate_port() {
    local port="$1"
    local service="$2"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Port invalide pour $service: $port"
        return 1
    fi
}

validate_weed_binary() {
    if ! command -v "$WEED_BINARY" >/dev/null 2>&1; then
        log_error "Binaire SeaweedFS non trouvé: $WEED_BINARY"
        log_info "Installez SeaweedFS ou définissez WEED_BINARY avec le chemin correct"
        return 1
    fi
    
    local version
    version=$("$WEED_BINARY" version 2>/dev/null | head -1 || echo "unknown")
    log_info "Utilisation de SeaweedFS: $version"
}

validate_ports() {
    local ports=()
    local services=()
    
    [[ "$START_MASTER" == "true" ]] && ports+=("$MASTER_PORT") && services+=("Master")
    [[ "$START_VOLUME" == "true" ]] && ports+=("$VOLUME_PORT") && services+=("Volume")
    [[ "$START_FILER" == "true" ]] && ports+=("$FILER_PORT") && services+=("Filer")
    [[ "$START_S3" == "true" ]] && ports+=("$S3_PORT") && services+=("S3")
    [[ "$START_MQ" == "true" ]] && ports+=("$MQ_PORT") && services+=("MQ")
    
    for i in "${!ports[@]}"; do
        validate_port "${ports[i]}" "${services[i]}" || return 1
    done
    
    # Vérification des ports en conflit
    local unique_ports=()
    for port in "${ports[@]}"; do
        if [[ " ${unique_ports[*]} " == *" $port "* ]]; then
            log_error "Conflit de port détecté: $port utilisé par plusieurs services"
            return 1
        fi
        unique_ports+=("$port")
    done
}

# Health check functions
is_port_available() {
    local host="$1"
    local port="$2"
    ! nc -z "$host" "$port" 2>/dev/null
}

check_required_ports() {
    log_step "Vérification des ports requis..."
    
    local ports_to_check=()
    [[ "$START_MASTER" == "true" ]] && ports_to_check+=("$MASTER_PORT")
    [[ "$START_VOLUME" == "true" ]] && ports_to_check+=("$VOLUME_PORT")
    [[ "$START_FILER" == "true" ]] && ports_to_check+=("$FILER_PORT")
    [[ "$START_S3" == "true" ]] && ports_to_check+=("$S3_PORT")
    [[ "$START_MQ" == "true" ]] && ports_to_check+=("$MQ_PORT")
    
    for port in "${ports_to_check[@]}"; do
        if ! is_port_available "127.0.0.1" "$port"; then
            log_error "Port $port est déjà utilisé. Libérez le port ou changez la configuration."
            return 1
        fi
    done
    
    log_info "✅ Tous les ports sont disponibles"
}

wait_for_service() {
    local service_name="$1"
    local host="$2"
    local port="$3"
    local max_attempts="${4:-$HEALTH_CHECK_TIMEOUT}"
    local check_type="${5:-http}"
    local endpoint="${6:-/}"
    
    log_step "En attente du service $service_name sur $host:$port..."
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        case "$check_type" in
            http)
                if curl -s --max-time 2 "http://$host:$port$endpoint" > /dev/null 2>&1 || 
                   curl -s --max-time 2 "http://$host:$port/status" > /dev/null 2>&1; then
                    log_info "✅ $service_name est prêt"
                    return 0
                fi
                ;;
            tcp)
                if nc -z "$host" "$port" 2>/dev/null; then
                    log_info "✅ $service_name est prêt"
                    return 0
                fi
                ;;
            grpc)
                # Simple TCP check for gRPC port (typically master port + 10000)
                if nc -z "$host" "$port" 2>/dev/null; then
                    log_info "✅ $service_name gRPC est prêt"
                    return 0
                fi
                ;;
        esac
        
        if [[ $attempt -eq 1 ]] || [[ $((attempt % 5)) -eq 0 ]]; then
            log_debug "En attente de $service_name... (tentative $attempt/$max_attempts)"
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log_error "❌ $service_name n'a pas démarré dans le délai imparti ($((max_attempts * 2)) secondes)"
    return 1
}

# Component management functions
start_master() {
    log_step "Démarrage du serveur Master SeaweedFS..."
    
    local raft_flag=""
    if [[ "$USE_RAFT" == "true" ]]; then
        raft_flag="-raftHashicorp"
        log_info "Mode Raft activé"
    fi
    
    local metrics_flag=""
    if [[ "$ENABLE_METRICS" == "true" ]]; then
        metrics_flag="-metricsPort=$METRICS_PORT -metricsAddress=127.0.0.1"
        log_info "Métriques activées sur le port $METRICS_PORT"
    fi
    
    mkdir -p "$DATA_DIR/master"
    
    local cmd=(
        "$WEED_BINARY" -v="$VERBOSE" master
        -port="$MASTER_PORT"
        -mdir="$DATA_DIR/master"
        $raft_flag
        -electionTimeout="1s"
        -volumeSizeLimitMB="$VOLUME_SIZE_LIMIT"
        -ip="127.0.0.1"
        -ip.bind="0.0.0.0"
        $metrics_flag
        -defaultReplication="000"
    )
    
    log_debug "Commande Master: ${cmd[*]}"
    
    nohup "${cmd[@]}" > "$DATA_DIR/master.log" 2>&1 &
    local pid=$!
    echo $pid > "$DATA_DIR/master.pid"
    
    log_info "Master démarré avec PID: $pid"
    
    # Wait for master HTTP and gRPC
    if ! wait_for_service "Master" "127.0.0.1" "$MASTER_PORT" "$STARTUP_TIMEOUT" "http"; then
        show_component_logs "master" 50
        return 1
    fi
    
    local grpc_port=$((MASTER_PORT + 10000))
    if ! wait_for_service "Master gRPC" "127.0.0.1" "$grpc_port" "$STARTUP_TIMEOUT" "grpc"; then
        show_component_logs "master" 50
        return 1
    fi
    
    log_info "✅ Master SeaweedFS démarré avec succès"
}

start_volume() {
    log_step "Démarrage du serveur Volume SeaweedFS..."
    
    mkdir -p "$DATA_DIR/volume"
    
    local metrics_flag=""
    if [[ "$ENABLE_METRICS" == "true" ]]; then
        metrics_flag="-metricsPort=$((METRICS_PORT + 1)) -metricsAddress=127.0.0.1"
    fi
    
    local cmd=(
        "$WEED_BINARY" -v="$VERBOSE" volume
        -port="$VOLUME_PORT"
        -dir="$DATA_DIR/volume"
        -max="$VOLUME_MAX"
        -mserver="127.0.0.1:$MASTER_PORT"
        -preStopSeconds=1
        -ip="127.0.0.1"
        -ip.bind="0.0.0.0"
        $metrics_flag
    )
    
    log_debug "Commande Volume: ${cmd[*]}"
    
    nohup "${cmd[@]}" > "$DATA_DIR/volume.log" 2>&1 &
    local pid=$!
    echo $pid > "$DATA_DIR/volume.pid"
    
    log_info "Volume Server démarré avec PID: $pid"
    
    if ! wait_for_service "Volume Server" "127.0.0.1" "$VOLUME_PORT" "$STARTUP_TIMEOUT" "http"; then
        show_component_logs "volume" 50
        return 1
    fi
    
    log_info "✅ Volume Server démarré avec succès"
}

start_filer() {
    log_step "Démarrage du Filer SeaweedFS..."
    
    mkdir -p "$DATA_DIR/filer"
    
    local metrics_flag=""
    if [[ "$ENABLE_METRICS" == "true" ]]; then
        metrics_flag="-metricsPort=$((METRICS_PORT + 2)) -metricsAddress=127.0.0.1"
    fi
    
    local cmd=(
        "$WEED_BINARY" -v="$VERBOSE" filer
        -port="$FILER_PORT"
        -defaultStoreDir="$DATA_DIR/filer"
        -master="127.0.0.1:$MASTER_PORT"
        -maxMB="$FILER_MAX_MB"
        -ip="127.0.0.1"
        -ip.bind="0.0.0.0"
        $metrics_flag
    )
    
    log_debug "Commande Filer: ${cmd[*]}"
    
    nohup "${cmd[@]}" > "$DATA_DIR/filer.log" 2>&1 &
    local pid=$!
    echo $pid > "$DATA_DIR/filer.pid"
    
    log_info "Filer démarré avec PID: $pid"
    
    if ! wait_for_service "Filer" "127.0.0.1" "$FILER_PORT" "$STARTUP_TIMEOUT" "http"; then
        show_component_logs "filer" 50
        return 1
    fi
    
    log_info "✅ Filer démarré avec succès"
}

start_s3() {
    log_step "Démarrage de la passerelle S3 SeaweedFS..."
    
    local s3_config=""
    if [[ -n "$S3_CONFIG_FILE" && -f "$S3_CONFIG_FILE" ]]; then
        s3_config="-config=$S3_CONFIG_FILE"
        log_info "Utilisation du fichier de configuration S3: $S3_CONFIG_FILE"
    fi
    
    local cmd=(
        "$WEED_BINARY" -v="$VERBOSE" s3
        -port="$S3_PORT"
        -filer="127.0.0.1:$FILER_PORT"
        -allowEmptyFolder=false
        -allowDeleteBucketNotEmpty=true
        $s3_config
        -ip.bind="0.0.0.0"
    )
    
    log_debug "Commande S3: ${cmd[*]}"
    
    nohup "${cmd[@]}" > "$DATA_DIR/s3.log" 2>&1 &
    local pid=$!
    echo $pid > "$DATA_DIR/s3.pid"
    
    log_info "S3 Gateway démarré avec PID: $pid"
    
    if ! wait_for_service "S3 Gateway" "127.0.0.1" "$S3_PORT" "$STARTUP_TIMEOUT" "http"; then
        show_component_logs "s3" 50
        return 1
    fi
    
    log_info "✅ S3 Gateway démarré avec succès"
}

start_mq() {
    log_step "Démarrage du broker MQ SeaweedFS..."
    
    local cmd=(
        "$WEED_BINARY" -v="$VERBOSE" mq.broker
        -port="$MQ_PORT"
        -master="127.0.0.1:$MASTER_PORT"
        -ip="127.0.0.1"
        -logFlushInterval=0
    )
    
    log_debug "Commande MQ: ${cmd[*]}"
    
    nohup "${cmd[@]}" > "$DATA_DIR/mq.log" 2>&1 &
    local pid=$!
    echo $pid > "$DATA_DIR/mq.pid"
    
    log_info "MQ Broker démarré avec PID: $pid"
    
    if ! wait_for_service "MQ Broker" "127.0.0.1" "$MQ_PORT" "$STARTUP_TIMEOUT" "tcp"; then
        show_component_logs "mq" 50
        return 1
    fi
    
    # Donner du temps supplémentaire au broker pour s'enregistrer
    log_step "Attente de l'enregistrement du broker MQ..."
    sleep 10
    
    log_info "✅ MQ Broker démarré avec succès"
}

# Utility functions
show_component_logs() {
    local component="$1"
    local lines="${2:-20}"
    
    log_error "Dernières $lines lignes du log $component:"
    if [[ -f "$DATA_DIR/$component.log" ]]; then
        tail -n "$lines" "$DATA_DIR/$component.log" || echo "Impossible de lire le log $component"
    else
        echo "Fichier de log non trouvé: $DATA_DIR/$component.log"
    fi
}

check_cluster_health() {
    log_step "Vérification de la santé du cluster..."
    
    if [[ "$START_MASTER" != "true" ]]; then
        log_info "Master non démarré, vérification de santé ignorée"
        return 0
    fi
    
    local health_url="http://127.0.0.1:$MASTER_PORT/cluster/health"
    
    if curl -s --max-time 5 "$health_url" > /dev/null 2>&1; then
        log_info "✅ Cluster en bonne santé"
        return 0
    else
        log_warn "⚠️  Impossible de vérifier la santé du cluster"
        return 1
    fi
}

show_status() {
    log_step "État du cluster SeaweedFS..."
    
    echo -e "\n${BOLD}=== État des Processus ===${NC}"
    local components=("master" "volume" "filer" "s3" "mq")
    local running=0
    local total=0
    
    for component in "${components[@]}"; do
        local pid_file="$DATA_DIR/$component.pid"
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "  ✅ ${GREEN}$component${NC} (PID: $pid) ${GREEN}● En cours${NC}"
                ((running++))
            else
                echo -e "  ❌ ${RED}$component${NC} (PID: $pid) ${RED}● Arrêté${NC}"
            fi
            ((total++))
        fi
    done
    
    echo -e "\n${BOLD}=== URLs des Services ===${NC}"
    [[ "$START_MASTER" == "true" ]] && echo "  Master:    http://127.0.0.1:$MASTER_PORT"
    [[ "$START_VOLUME" == "true" ]] && echo "  Volume:    http://127.0.0.1:$VOLUME_PORT"
    [[ "$START_FILER" == "true" ]] && echo "  Filer:     http://127.0.0.1:$FILER_PORT"
    [[ "$START_S3" == "true" ]] && echo "  S3:        http://127.0.0.1:$S3_PORT"
    [[ "$START_MQ" == "true" ]] && echo "  MQ:        tcp://127.0.0.1:$MQ_PORT"
    
    if [[ "$ENABLE_METRICS" == "true" ]]; then
        echo -e "\n${BOLD}=== Métriques ===${NC}"
        [[ "$START_MASTER" == "true" ]] && echo "  Master:    http://127.0.0.1:$METRICS_PORT/metrics"
        [[ "$START_VOLUME" == "true" ]] && echo "  Volume:    http://127.0.0.1:$((METRICS_PORT + 1))/metrics"
        [[ "$START_FILER" == "true" ]] && echo "  Filer:     http://127.0.0.1:$((METRICS_PORT + 2))/metrics"
    fi
    
    echo -e "\n${BOLD}=== Répertoires ===${NC}"
    echo "  Données:   $DATA_DIR"
    echo "  Logs:      $DATA_DIR/*.log"
    
    if [[ "$running" -eq "$total" && "$total" -gt 0 ]]; then
        echo -e "\n${GREEN}✅ Tous les services ($running/$total) sont en cours d'exécution${NC}"
    else
        echo -e "\n${YELLOW}⚠️  $running/$total services en cours d'exécution${NC}"
    fi
}

stop_all() {
    log_step "Arrêt de tous les composants SeaweedFS..."
    
    local components=("mq" "s3" "filer" "volume" "master")
    local stopped=0
    
    for component in "${components[@]}"; do
        local pid_file="$DATA_DIR/$component.pid"
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Arrêt de $component (PID: $pid)"
                
                # Signal TERM gracieux
                kill -TERM "$pid" 2>/dev/null && \
                (sleep 5; kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null) &
                local kill_pid=$!
                
                # Attendre l'arrêt
                if wait_for_process_stop "$pid" 10; then
                    log_info "✅ $component arrêté gracieusement"
                else
                    wait "$kill_pid" 2>/dev/null
                    log_warn "⚠️  $component arrêté de force"
                fi
                
                ((stopped++))
            fi
            rm -f "$pid_file"
        fi
    done
    
    # Nettoyage des processus restants
    pkill -f "weed.*(master|volume|filer|s3|mq)" 2>/dev/null || true
    
    log_info "✅ $stopped composants arrêtés"
}

wait_for_process_stop() {
    local pid="$1"
    local timeout="${2:-10}"
    local count=0
    
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done
    
    ! kill -0 "$pid" 2>/dev/null
}

# Gestion des arguments
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Démarre les composants SeaweedFS individuellement pour les tests et le développement.

OPTIONS:
    -h, --help              Affiche ce message d'aide
    -v, --version           Affiche la version
    -d, --data-dir DIR      Répertoire de données (défaut: $DEFAULT_DATA_DIR)
    -b, --binary PATH       Chemin vers le binaire weed (défaut: weed)
    -v, --verbose LEVEL     Niveau de verbosité 0-3 (défaut: 1)
    
    --master-port PORT      Port du master (défaut: $MASTER_PORT)
    --volume-port PORT      Port du volume (défaut: $VOLUME_PORT)
    --filer-port PORT       Port du filer (défaut: $FILER_PORT)
    --s3-port PORT          Port S3 (défaut: $S3_PORT)
    --mq-port PORT          Port MQ (défaut: $MQ_PORT)
    --metrics-port PORT     Port des métriques (défaut: $METRICS_PORT)
    
    --no-master             Ne pas démarrer le master
    --no-volume             Ne pas démarrer le volume
    --no-filer              Ne pas démarrer le filer
    --with-s3               Démarrer la passerelle S3
    --with-mq               Démarrer le broker MQ
    --s3-config FILE        Fichier de configuration S3
    
    --volume-max NUM        Volumes maximum (défaut: $VOLUME_MAX)
    --volume-size-limit MB  Limite de taille des volumes (défaut: $VOLUME_SIZE_LIMIT)
    --filer-max-mb MB       MB maximum du filer (défaut: $FILER_MAX_MB)
    --no-raft               Désactiver Raft pour le master
    --no-metrics            Désactiver les métriques
    
    --startup-timeout SEC   Timeout de démarrage (défaut: $STARTUP_TIMEOUT)
    --health-timeout SEC    Timeout de santé (défaut: $HEALTH_CHECK_TIMEOUT)
    
    --stop                  Arrêter tous les composants
    --status                Afficher l'état du cluster
    --restart               Redémarrer les composants
    --no-cleanup-trap       Désactiver le nettoyage automatique
    
EXEMPLES:
    # Cluster de base (master + volume + filer)
    $SCRIPT_NAME
    
    # Avec S3 et métriques
    $SCRIPT_NAME --with-s3 --s3-config ./s3.json
    
    # Ports personnalisés
    $SCRIPT_NAME --master-port 9334 --volume-port 8081 --filer-port 8889
    
    # Arrêt propre
    $SCRIPT_NAME --stop

VARIABLES D'ENVIRONNEMENT:
    WEED_DATA_DIR          Répertoire de données
    WEED_BINARY            Chemin vers le binaire weed
    S3_CONFIG_FILE         Fichier de configuration S3
    MASTER_PORT            Port du master
    VOLUME_PORT            Port du volume
    FILER_PORT             Port du filer

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "SeaweedFS Startup Script v$SCRIPT_VERSION"
                exit 0
                ;;
            -d|--data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            -b|--binary)
                WEED_BINARY="$2"
                shift 2
                ;;
            --master-port)
                MASTER_PORT="$2"
                shift 2
                ;;
            --volume-port)
                VOLUME_PORT="$2"
                shift 2
                ;;
            --filer-port)
                FILER_PORT="$2"
                shift 2
                ;;
            --s3-port)
                S3_PORT="$2"
                shift 2
                ;;
            --mq-port)
                MQ_PORT="$2"
                shift 2
                ;;
            --metrics-port)
                METRICS_PORT="$2"
                shift 2
                ;;
            --no-master)
                START_MASTER=false
                shift
                ;;
            --no-volume)
                START_VOLUME=false
                shift
                ;;
            --no-filer)
                START_FILER=false
                shift
                ;;
            --with-s3)
                START_S3=true
                shift
                ;;
            --with-mq)
                START_MQ=true
                shift
                ;;
            --s3-config)
                S3_CONFIG_FILE="$2"
                shift 2
                ;;
            --volume-max)
                VOLUME_MAX="$2"
                shift 2
                ;;
            --volume-size-limit)
                VOLUME_SIZE_LIMIT="$2"
                shift 2
                ;;
            --filer-max-mb)
                FILER_MAX_MB="$2"
                shift 2
                ;;
            --no-raft)
                USE_RAFT=false
                shift
                ;;
            --no-metrics)
                ENABLE_METRICS=false
                shift
                ;;
            --startup-timeout)
                STARTUP_TIMEOUT="$2"
                shift 2
                ;;
            --health-timeout)
                HEALTH_CHECK_TIMEOUT="$2"
                shift 2
                ;;
            --no-cleanup-trap)
                CLEANUP_ON_EXIT=false
                shift
                ;;
            --stop)
                stop_all
                exit 0
                ;;
            --status)
                show_status
                exit 0
                ;;
            --restart)
                stop_all
                sleep 2
                shift
                ;;
            *)
                log_error "Option inconnue: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Fonction principale
main() {
    log_info "🚀 Démarrage des composants SeaweedFS"
    echo -e "Version: ${BOLD}$SCRIPT_VERSION${NC}"
    echo -e "Répertoire de données: ${BOLD}$DATA_DIR${NC}"
    echo -e "Binaire: ${BOLD}$WEED_BINARY${NC}"
    echo ""
    
    # Validation préalable
    validate_weed_binary || exit 1
    validate_ports || exit 1
    check_required_ports || exit 1
    
    # Création du répertoire de données
    mkdir -p "$DATA_DIR"
    log_info "Répertoire de données créé: $DATA_DIR"
    
    # Trap de nettoyage
    if [[ "$CLEANUP_ON_EXIT" == "true" ]]; then
        trap 'log_step "Nettoyage en cours..."; stop_all; log_info "Nettoyage terminé"; exit 0' EXIT INT TERM
    fi
    
    # Démarrage séquentiel des composants
    local components_started=()
    
    if [[ "$START_MASTER" == "true" ]]; then
        start_master && components_started+=("master")
    fi
    
    if [[ "$START_VOLUME" == "true" ]]; then
        start_volume && components_started+=("volume")
    fi
    
    if [[ "$START_FILER" == "true" ]]; then
        start_filer && components_started+=("filer")
    fi
    
    if [[ "$START_S3" == "true" ]]; then
        start_s3 && components_started+=("s3")
    fi
    
    if [[ "$START_MQ" == "true" ]]; then
        start_mq && components_started+=("mq")
    fi
    
    # Vérification finale
    echo ""
    check_cluster_health
    show_status
    
    if [[ ${#components_started[@]} -gt 0 ]]; then
        log_info "🎉 ${#components_started[@]} composants démarrés avec succès: ${components_started[*]}"
        echo ""
        echo -e "${GREEN}${BOLD}SeaweedFS est opérationnel!${NC}"
        echo ""
        echo "Pour arrêter: $SCRIPT_NAME --stop"
        echo "Pour voir l'état: $SCRIPT_NAME --status"
        echo ""
        echo -e "${YELLOW}Les logs sont disponibles dans: $DATA_DIR/${NC}"
    else
        log_warn "Aucun composant démarré"
    fi
}

# Point d'entrée
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
