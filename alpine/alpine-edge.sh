#!/bin/sh

set -eu

REPO_FILE="/etc/apk/repositories"
BACKUP_FILE="/etc/apk/repositories.pre-edge.$(date +%Y%m%d-%H%M%S)"

EDGE_MAIN="https://dl-cdn.alpinelinux.org/alpine/edge/main"
EDGE_COMMUNITY="https://dl-cdn.alpinelinux.org/alpine/edge/community"
EDGE_TESTING="https://dl-cdn.alpinelinux.org/alpine/edge/testing"

echo "===================================================="
echo " Alpine Linux -> EDGE Upgrade"
echo "===================================================="
echo

# --------------------------------------------------
# 1. Root prüfen
# --------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Dieses Skript muss als root ausgeführt werden."
    exit 1
fi

# --------------------------------------------------
# 2. Prüfen, ob apk vorhanden ist
# --------------------------------------------------

if ! command -v apk >/dev/null 2>&1; then
    echo "ERROR: apk wurde nicht gefunden."
    echo "Dieses Skript ist nur für Alpine Linux gedacht."
    exit 1
fi

echo "Aktuelle Alpine-Version:"
cat /etc/alpine-release || true

echo
echo "Aktuelle Repositories:"
cat "$REPO_FILE"

echo

# --------------------------------------------------
# 3. Repository-Datei sichern
# --------------------------------------------------

echo "Erstelle Backup:"
echo "  $BACKUP_FILE"

cp "$REPO_FILE" "$BACKUP_FILE"

# --------------------------------------------------
# 4. Edge-Repositories setzen
# --------------------------------------------------

echo
echo "Setze Alpine EDGE Repositories ..."

cat > "$REPO_FILE" <<EOF
$EDGE_MAIN
$EDGE_COMMUNITY
@testing $EDGE_TESTING
EOF

echo
echo "Neue Repository-Konfiguration:"
cat "$REPO_FILE"

echo

# --------------------------------------------------
# 5. Repository Index aktualisieren
# --------------------------------------------------

echo "Aktualisiere Paketindex ..."

apk update

# --------------------------------------------------
# 6. apk-tools zuerst aktualisieren
# --------------------------------------------------

echo
echo "Aktualisiere apk-tools ..."

apk add --upgrade apk-tools

# --------------------------------------------------
# 7. Komplettes System auf Edge migrieren
# --------------------------------------------------

echo
echo "Führe vollständiges Upgrade auf EDGE durch ..."

apk upgrade --available

# --------------------------------------------------
# 8. Paketdatenbank / Cache aufräumen
# --------------------------------------------------

echo
echo "Räume APK Cache auf ..."

apk cache clean 2>/dev/null || true

# --------------------------------------------------
# 9. Dateisystem synchronisieren
# --------------------------------------------------

echo
echo "Synchronisiere Dateisystem ..."

sync

# --------------------------------------------------
# 10. Ergebnis anzeigen
# --------------------------------------------------

echo
echo "===================================================="
echo " Upgrade abgeschlossen"
echo "===================================================="

echo
echo "Alpine-Version:"
cat /etc/alpine-release || true

echo
echo "Repositories:"
cat "$REPO_FILE"

echo
echo "APK-Version:"
apk --version

echo
echo "Das System verwendet jetzt Alpine EDGE."
echo
echo "Backup der vorherigen Repository-Konfiguration:"
echo "  $BACKUP_FILE"
echo
echo "Ein Neustart wird empfohlen."
echo
echo "  reboot"
echo
