#!/usr/bin/env bash
# Restore a backup produced by backup.sh into the running PostgreSQL
# container, then prove it worked by querying the data back out.
set -euo pipefail

CONTAINER="${PG_CONTAINER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-backups}"
ASSUME_YES=0
BACKUP_FILE=""

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        *) BACKUP_FILE="$arg" ;;
    esac
done

echo "== restore.sh =="

if [ -z "$BACKUP_FILE" ]; then
    BACKUP_FILE="$(ls -t "${BACKUP_DIR}"/*.dump 2>/dev/null | head -n1 || true)"
fi

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
    echo "FAIL: no backup file found (looked in ${BACKUP_DIR}/*.dump)." >&2
    exit 1
fi

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: container '$CONTAINER' is not running." >&2
    exit 1
fi

PG_USER="$(docker exec "$CONTAINER" printenv POSTGRES_USER)"
PG_DB="$(docker exec "$CONTAINER" printenv POSTGRES_DB)"

echo "About to restore '$BACKUP_FILE' into database '$PG_DB' (this replaces existing rows via --clean)."
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Continue? [y/N] " REPLY
    case "$REPLY" in
        [yY]*) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

echo "Restoring..."
docker exec -i "$CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" \
    --clean --if-exists --no-owner < "$BACKUP_FILE"

echo "Verifying: querying records table back out of PostgreSQL..."
COUNT="$(docker exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM records;")"
COUNT="$(echo "$COUNT" | tr -d '[:space:]')"

if [ -z "$COUNT" ] || [ "$COUNT" -lt 1 ]; then
    echo "FAIL: post-restore query returned no rows (count=${COUNT:-0})." >&2
    exit 1
fi

echo "PASS: restore verified -> 'records' table has ${COUNT} row(s) after restore."