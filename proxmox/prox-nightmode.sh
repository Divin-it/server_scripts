#!/bin/bash

# ============================================================
# Proxmox LXC Night Mode
# Host: gruewueserver
#
# 00:00:
#   - merkt sich alle aktuell laufenden LXCs
#   - CT 100 (Tailscale) bleibt immer aktiv
#   - fährt die übrigen LXCs in sinnvoller Reihenfolge herunter
#
# 06:00:
#   - startet nur LXCs, die vorher tatsächlich liefen
#   - berücksichtigt Abhängigkeiten / Boot-Reihenfolge
#
# Befehle:
#   lxc-night-mode.sh stop
#   lxc-night-mode.sh start
#   lxc-night-mode.sh status
# ============================================================

set -u

# ------------------------------------------------------------
# GRUNDEINSTELLUNGEN
# ------------------------------------------------------------

STATE_DIR="/var/lib/lxc-night-mode"
STATE_FILE="$STATE_DIR/running-containers"
LOG_FILE="/var/log/lxc-night-mode.log"

mkdir -p "$STATE_DIR"

# Container, die niemals gestoppt werden
EXCLUDE_IDS=("100")

# Standardwartezeit zwischen einzelnen Starts
START_DELAY=4

# Standardwartezeit zwischen Gruppen
GROUP_DELAY=8

# Ollama braucht beim Start etwas länger
OLLAMA_DELAY=15

# Timeout für sauberen Shutdown
SHUTDOWN_TIMEOUT=60


# ------------------------------------------------------------
# BOOT-REIHENFOLGE
# ------------------------------------------------------------

# 1. Netzwerk / DNS
NETWORK=(
    104     # AdGuard
)

# 2. Infrastruktur / Identity / Backend
BACKENDS=(
    102     # Authentik
)

# 3. AI Backend
AI_BACKEND=(
    105     # Ollama
)

# 4. Frühe Basis-Anwendungen
APPLICATIONS_EARLY=(
    103     # Vaultwarden
    111     # Copyparty
)

# 5. Anwendungen
APPLICATIONS=(
    107     # Kaneo
    108     # Paperless-ngx
    109     # Teable
)

# 6. AI Frontend
AI_FRONTENDS=(
    106     # OpenWebUI
)

# 7. Reverse Proxy
PROXY=(
    101     # Caddy
)

# 8. Dashboard / Monitoring
MONITORING=(
    110     # Glance
)


# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}


# ------------------------------------------------------------
# HILFSFUNKTIONEN
# ------------------------------------------------------------

get_name() {
    local id="$1"

    pct config "$id" 2>/dev/null \
        | awk -F': ' '/^hostname:/ {print $2; exit}'
}


container_exists() {
    local id="$1"

    pct config "$id" >/dev/null 2>&1
}


container_running() {
    local id="$1"

    [[ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" == "running" ]]
}


is_excluded() {
    local id="$1"

    for excluded in "${EXCLUDE_IDS[@]}"; do
        if [[ "$id" == "$excluded" ]]; then
            return 0
        fi
    done

    return 1
}


was_running() {
    local id="$1"

    [[ -f "$STATE_FILE" ]] && grep -qx "$id" "$STATE_FILE"
}


get_all_configured_ids() {
    printf "%s\n" \
        "${NETWORK[@]}" \
        "${BACKENDS[@]}" \
        "${AI_BACKEND[@]}" \
        "${APPLICATIONS_EARLY[@]}" \
        "${APPLICATIONS[@]}" \
        "${AI_FRONTENDS[@]}" \
        "${PROXY[@]}" \
        "${MONITORING[@]}"
}


is_configured() {
    local id="$1"

    get_all_configured_ids | grep -qx "$id"
}


# ------------------------------------------------------------
# START EINES CONTAINERS
# ------------------------------------------------------------

start_container() {
    local id="$1"

    local name
    name="$(get_name "$id")"

    if ! was_running "$id"; then
        log "CT $id (${name:-unknown}) lief vor dem Night Mode nicht -> übersprungen."
        return
    fi

    if is_excluded "$id"; then
        log "CT $id (${name:-unknown}) ist dauerhaft aktiv -> übersprungen."
        return
    fi

    if ! container_exists "$id"; then
        log "WARNUNG: CT $id existiert nicht mehr."
        return
    fi

    if container_running "$id"; then
        log "CT $id (${name:-unknown}) läuft bereits."
        return
    fi

    log "Starte CT $id (${name:-unknown}) ..."

    if pct start "$id"; then
        log "CT $id (${name:-unknown}) erfolgreich gestartet."
    else
        log "FEHLER: CT $id (${name:-unknown}) konnte nicht gestartet werden."
        return
    fi

    sleep "$START_DELAY"
}


# ------------------------------------------------------------
# STOP EINES CONTAINERS
# ------------------------------------------------------------

stop_container() {
    local id="$1"

    local name
    name="$(get_name "$id")"

    if is_excluded "$id"; then
        log "CT $id (${name:-unknown}) bleibt dauerhaft aktiv."
        return
    fi

    if ! container_exists "$id"; then
        log "WARNUNG: CT $id existiert nicht."
        return
    fi

    if ! container_running "$id"; then
        log "CT $id (${name:-unknown}) läuft bereits nicht."
        return
    fi

    log "Fahre CT $id (${name:-unknown}) herunter ..."

    if pct shutdown "$id" --timeout "$SHUTDOWN_TIMEOUT"; then
        log "CT $id (${name:-unknown}) wurde sauber heruntergefahren."
    else
        log "WARNUNG: CT $id (${name:-unknown}) reagiert nicht auf Shutdown."

        sleep 3

        if container_running "$id"; then
            log "Erzwinge Stop für CT $id (${name:-unknown})."

            if pct stop "$id"; then
                log "CT $id (${name:-unknown}) wurde hart gestoppt."
            else
                log "FEHLER: CT $id (${name:-unknown}) konnte nicht gestoppt werden."
            fi
        fi
    fi
}


# ------------------------------------------------------------
# GRUPPE STARTEN
# ------------------------------------------------------------

start_group() {
    local group_name="$1"
    shift

    local containers=("$@")

    if (( ${#containers[@]} == 0 )); then
        return
    fi

    log ""
    log "------------------------------------------"
    log "Starte Gruppe: $group_name"
    log "------------------------------------------"

    for id in "${containers[@]}"; do
        start_container "$id"
    done

    sleep "$GROUP_DELAY"
}


# ------------------------------------------------------------
# GRUPPE RÜCKWÄRTS STOPPEN
# ------------------------------------------------------------

stop_group_reverse() {
    local group_name="$1"
    shift

    local containers=("$@")

    if (( ${#containers[@]} == 0 )); then
        return
    fi

    log ""
    log "------------------------------------------"
    log "Stoppe Gruppe: $group_name"
    log "------------------------------------------"

    for ((i=${#containers[@]}-1; i>=0; i--)); do
        stop_container "${containers[$i]}"
    done
}


# ------------------------------------------------------------
# NICHT ZUGEORDNETE CONTAINER
# ------------------------------------------------------------

get_unassigned_running_containers() {
    pct list \
        | awk 'NR>1 && $2=="running" {print $1}' \
        | while read -r id; do

            if is_excluded "$id"; then
                continue
            fi

            if ! is_configured "$id"; then
                echo "$id"
            fi

        done
}


get_unassigned_saved_containers() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi

    while read -r id; do

        [[ -z "$id" ]] && continue

        if is_excluded "$id"; then
            continue
        fi

        if ! is_configured "$id"; then
            echo "$id"
        fi

    done < "$STATE_FILE"
}


# ------------------------------------------------------------
# NIGHT MODE AKTIVIEREN
# ------------------------------------------------------------

stop_containers() {
    log ""
    log "=========================================="
    log "LXC NIGHT MODE WIRD AKTIVIERT"
    log "=========================================="

    > "$STATE_FILE"

    log ""
    log "Speichere aktuell laufende Container:"

    pct list \
        | awk 'NR>1 && $2=="running" {print $1}' \
        | while read -r id; do

            local_name="$(get_name "$id")"

            if is_excluded "$id"; then
                log "CT $id (${local_name:-unknown}) bleibt aktiv."
                continue
            fi

            echo "$id" >> "$STATE_FILE"
            log "CT $id (${local_name:-unknown}) war aktiv."

        done

    mapfile -t UNASSIGNED < <(get_unassigned_running_containers)

    if (( ${#UNASSIGNED[@]} > 0 )); then
        log ""
        log "WARNUNG: Nicht zugeordnete Container erkannt:"

        for id in "${UNASSIGNED[@]}"; do
            log "CT $id ($(get_name "$id"))"
        done
    fi

    # Shutdown in umgekehrter Boot-Reihenfolge

    stop_group_reverse \
        "Monitoring / Dashboard" \
        "${MONITORING[@]}"

    stop_group_reverse \
        "Reverse Proxy" \
        "${PROXY[@]}"

    stop_group_reverse \
        "AI Frontends" \
        "${AI_FRONTENDS[@]}"

    stop_group_reverse \
        "Anwendungen" \
        "${APPLICATIONS[@]}"

    if (( ${#UNASSIGNED[@]} > 0 )); then
        stop_group_reverse \
            "Nicht zugeordnete Container" \
            "${UNASSIGNED[@]}"
    fi

    stop_group_reverse \
        "Frühe Anwendungen" \
        "${APPLICATIONS_EARLY[@]}"

    stop_group_reverse \
        "AI Backend" \
        "${AI_BACKEND[@]}"

    stop_group_reverse \
        "Backends / Identity" \
        "${BACKENDS[@]}"

    stop_group_reverse \
        "Netzwerk / DNS" \
        "${NETWORK[@]}"

    log ""
    log "=========================================="
    log "NIGHT MODE AKTIV"
    log "=========================================="
}


# ------------------------------------------------------------
# NIGHT MODE BEENDEN
# ------------------------------------------------------------

start_containers() {
    log ""
    log "=========================================="
    log "LXC NIGHT MODE WIRD BEENDET"
    log "=========================================="

    if [[ ! -s "$STATE_FILE" ]]; then
        log "Keine gespeicherten Container vorhanden."
        log "Es wird nichts gestartet."
        exit 0
    fi

    mapfile -t UNASSIGNED < <(get_unassigned_saved_containers)

    # 1. DNS
    start_group \
        "Netzwerk / DNS" \
        "${NETWORK[@]}"

    # 2. Infrastruktur / Identity
    start_group \
        "Backends / Identity" \
        "${BACKENDS[@]}"

    # 3. Ollama separat
    log ""
    log "------------------------------------------"
    log "Starte AI Backend"
    log "------------------------------------------"

    for id in "${AI_BACKEND[@]}"; do
        start_container "$id"
    done

    log "Warte zusätzlich ${OLLAMA_DELAY}s auf Ollama ..."
    sleep "$OLLAMA_DELAY"

    # 4. Basis-Anwendungen
    start_group \
        "Frühe Anwendungen" \
        "${APPLICATIONS_EARLY[@]}"

    # 5. Anwendungen
    start_group \
        "Anwendungen" \
        "${APPLICATIONS[@]}"

    # 6. Unbekannte Container
    if (( ${#UNASSIGNED[@]} > 0 )); then
        log ""
        log "WARNUNG: Starte nicht zugeordnete Container."

        start_group \
            "Nicht zugeordnete Container" \
            "${UNASSIGNED[@]}"
    fi

    # 7. OpenWebUI
    start_group \
        "AI Frontends" \
        "${AI_FRONTENDS[@]}"

    # 8. Caddy
    start_group \
        "Reverse Proxy" \
        "${PROXY[@]}"

    # 9. Glance
    start_group \
        "Monitoring / Dashboard" \
        "${MONITORING[@]}"

    rm -f "$STATE_FILE"

    log ""
    log "=========================================="
    log "NIGHT MODE BEENDET"
    log "Alle zuvor laufenden LXCs wurden bearbeitet."
    log "=========================================="
}


# ------------------------------------------------------------
# STATUS
# ------------------------------------------------------------

show_status() {
    echo
    echo "=========================================="
    echo "         PROXMOX LXC NIGHT MODE"
    echo "=========================================="
    echo

    echo "Dauerhaft aktiv:"
    for id in "${EXCLUDE_IDS[@]}"; do
        echo "  CT $id ($(get_name "$id"))"
    done

    echo
    echo "Boot-Reihenfolge:"
    echo

    echo "1. Netzwerk / DNS"
    for id in "${NETWORK[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "2. Backends / Identity"
    for id in "${BACKENDS[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "3. AI Backend"
    for id in "${AI_BACKEND[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "4. Frühe Anwendungen"
    for id in "${APPLICATIONS_EARLY[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "5. Anwendungen"
    for id in "${APPLICATIONS[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "6. AI Frontends"
    for id in "${AI_FRONTENDS[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "7. Reverse Proxy"
    for id in "${PROXY[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "8. Monitoring / Dashboard"
    for id in "${MONITORING[@]}"; do
        echo "   CT $id ($(get_name "$id"))"
    done

    echo
    echo "------------------------------------------"

    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo "Night Mode State-Datei vorhanden."
        echo
        echo "Vor Night Mode laufende Container:"

        while read -r id; do
            [[ -z "$id" ]] && continue
            echo "  CT $id ($(get_name "$id"))"
        done < "$STATE_FILE"

    else
        echo
        echo "Night Mode momentan nicht aktiv."
    fi

    echo
}


# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------

case "${1:-}" in

    stop)
        stop_containers
        ;;

    start)
        start_containers
        ;;

    status)
        show_status
        ;;

    *)
        echo "Usage:"
        echo "  $0 stop"
        echo "  $0 start"
        echo "  $0 status"
        exit 1
        ;;

esac
