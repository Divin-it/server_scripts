#!/usr/bin/env bash
# Safe, unattended LXC updates for Proxmox. Run on the Proxmox host as root.
set -Eeuo pipefail

LOG_FILE="/var/log/lxc-update.log"
LOCK_FILE="/run/lock/lxc-safe-update.lock"
STATE_DIR="/var/lib/lxc-safe-update"
SUCCESS_INDEX="$STATE_DIR/successful-snapshots.tsv"
RETENTION_DAYS=3
HEALTH_RETRIES=5
HEALTH_DELAY_SECONDS=15
SNAPSHOT_PREFIX="autoupdate"

# Applications first; identity and shared network infrastructure last.
UPDATE_ORDER=(111 110 109 108 107 106 105 103 102 101 104 100)

if (( EUID != 0 )); then
  printf '%s\n' 'ERROR: Run this script as root on the Proxmox host.' >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")"
touch "$LOG_FILE" "$SUCCESS_INDEX"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf '%s Another update run is already active; exiting.\n' "$(date '+%F %T%z')" >>"$LOG_FILE"
  exit 0
fi
exec >>"$LOG_FILE" 2>&1

log() { printf '%s %s\n' "$(date '+%F %T%z')" "$*"; }
fail() { log "ERROR: $*"; return 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: Required command '$1' is missing."; exit 1; }
}

for command_name in pct flock curl date; do require_command "$command_name"; done
if ! command -v dig >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
  log "ERROR: Neither dig nor nslookup is installed; AdGuard health check cannot run safely."
  exit 1
fi

ct_name() {
  case "$1" in
    100) echo "Tailscale";; 101) echo "Caddy";; 102) echo "Authentik";;
    101) echo "Vaultwarden";; 104) echo "AdGuard Home";; 105) echo "Ollama";;
    102) echo "OpenWebUI";; 107) echo "Kaneo";; 108) echo "Paperless-ngx";;
    103) echo "Teable";; 110) echo "Glance";; 111) echo "Copyparty";;
  esac
}

os_type() {
  case "$1" in
    100|101|103|104|111) echo "alpine";;
    *) echo "debian";;
  esac
}

is_community_update_ct() {
  case "$1" in 102|103|108|109|110) return 0;; *) return 1;; esac
}

container_running() {
  pct status "$1" 2>/dev/null | grep -qx 'status: running'
}

update_os() {
  local ct="$1" os
  os="$(os_type "$ct")"
  log "CT $ct ($(ct_name "$ct")): starting $os package update."
  if [[ "$os" == "debian" ]]; then
    pct exec "$ct" -- sh -lc \
      'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs'
  else
    pct exec "$ct" -- sh -lc 'apk update && apk upgrade'
  fi
}

update_community_app() {
  local ct="$1"
  if ! is_community_update_ct "$ct"; then
    return 0
  fi
  log "CT $ct ($(ct_name "$ct")): starting approved Community Script app update."
  # Community Scripts commonly provide this wrapper. Fail safely if it is absent.
  pct exec "$ct" -- sh -lc 'command -v update >/dev/null 2>&1 && update' || return 1
}

http_check() {
  local url="$1"
  curl --fail --silent --show-error --location --connect-timeout 5 --max-time 20 "$url" >/dev/null
}

dns_check() {
  local server="192.168.178.2"
  if command -v dig >/dev/null 2>&1; then
    dig +time=3 +tries=1 +short "@$server" home.gruwu.de A | grep -Eq '^[0-9a-fA-F:.]+$'
  else
    nslookup -timeout=3 home.gruwu.de "$server" >/dev/null 2>&1
  fi
}

tailscale_check() {
  pct exec 100 -- sh -lc 'tailscale status --peers=false >/dev/null 2>&1'
}

health_check_once() {
  case "$1" in
    100) tailscale_check;;
    101) http_check 'http://192.168.178.48/' ;;
    102) http_check 'https://sso.home.gruwu.de/' ;;
    103) http_check 'https://vault.home.gruwu.de/' ;;
    104) dns_check;;
    105) http_check 'http://192.168.178.46:11434/api/tags' ;;
    106) http_check 'http://192.168.178.43:8080/' ;;
    107) http_check 'http://192.168.178.44:5173/' ;;
    108) http_check 'http://192.168.178.42:8000/' ;;
    109) http_check 'http://192.168.178.41:3000/' ;;
    110) http_check 'http://192.168.178.40:8080/' ;;
    111) http_check 'http://192.168.178.39:3923/' ;;
    *) return 1;;
  esac
}

health_check() {
  local ct="$1" attempt
  for ((attempt=1; attempt<=HEALTH_RETRIES; attempt++)); do
    if health_check_once "$ct"; then
      log "CT $ct ($(ct_name "$ct")): health check passed (attempt $attempt/$HEALTH_RETRIES)."
      return 0
    fi
    log "WARNING: CT $ct ($(ct_name "$ct")): health check failed (attempt $attempt/$HEALTH_RETRIES)."
    (( attempt < HEALTH_RETRIES )) && sleep "$HEALTH_DELAY_SECONDS"
  done
  return 1
}

record_success() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date +%s)" >>"$SUCCESS_INDEX"
}

cleanup_successful_snapshots() {
  local cutoff now ct snapshot created kept=0
  now="$(date +%s)"
  cutoff=$((now - RETENTION_DAYS * 86400))
  local temporary="$SUCCESS_INDEX.new"
  : >"$temporary"
  while IFS=$'\t' read -r ct snapshot created; do
    [[ -z "${ct:-}" || -z "${snapshot:-}" || -z "${created:-}" ]] && continue
    if (( created <= cutoff )); then
      if pct listsnapshot "$ct" 2>/dev/null | awk '{print $2}' | grep -Fxq "$snapshot"; then
        if pct delsnapshot "$ct" "$snapshot"; then
          log "CT $ct: removed successful snapshot $snapshot (older than $RETENTION_DAYS days)."
          continue
        fi
        log "WARNING: CT $ct: could not remove successful snapshot $snapshot; keeping its index entry."
      else
        log "CT $ct: indexed snapshot $snapshot no longer exists; removing stale index entry."
        continue
      fi
    fi
    printf '%s\t%s\t%s\n' "$ct" "$snapshot" "$created" >>"$temporary"
    kept=$((kept + 1))
  done <"$SUCCESS_INDEX"
  mv "$temporary" "$SUCCESS_INDEX"
  log "Snapshot retention complete; $kept successful snapshot record(s) retained. Failed-update snapshots are never indexed or deleted."
}

log "===== LXC safe update run started ====="
cleanup_successful_snapshots

for ct in "${UPDATE_ORDER[@]}"; do
  name="$(ct_name "$ct")"
  if ! container_running "$ct"; then
    log "ERROR: CT $ct ($name) is not running; no snapshot and no update attempted."
    continue
  fi

  snapshot="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  log "CT $ct ($name): creating pre-update snapshot $snapshot."
  if ! pct snapshot "$ct" "$snapshot" --description "Automated pre-update snapshot $(date -Is)"; then
    log "ERROR: CT $ct ($name): snapshot failed; update deliberately skipped."
    continue
  fi

  if ! update_os "$ct"; then
    log "ERROR: CT $ct ($name): OS update failed. Snapshot $snapshot is retained; no automatic rollback is performed."
    continue
  fi
  if ! update_community_app "$ct"; then
    log "ERROR: CT $ct ($name): approved app update failed. Snapshot $snapshot is retained; no automatic rollback is performed."
    continue
  fi
  if ! health_check "$ct"; then
    log "ERROR: CT $ct ($name): HEALTH CHECK FAILED. Snapshot $snapshot is retained for manual investigation/rollback; no automatic rollback is performed."
    continue
  fi

  record_success "$ct" "$snapshot"
  log "CT $ct ($name): update completed successfully; snapshot $snapshot will be eligible for cleanup after $RETENTION_DAYS days."
done

log "===== LXC safe update run finished ====="
