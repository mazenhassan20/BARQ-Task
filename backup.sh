#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${PG_CONTAINER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-backups}"

echo "== backup.sh =="

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: container '$CONTAINER' is not running." >&2
    exit 1
fi

# Read the real DB user/name from the container's own environment.
PG_USER="$(docker exec "$CONTAINER" printenv POSTGRES_USER)"
PG_DB="$(docker exec "$CONTAINER" printenv POSTGRES_DB)"

if ! docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    echo "FAIL: postgres is not ready (pg_isready failed)." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${BACKUP_DIR}/${PG_DB}_${TIMESTAMP}.dump"

echo "Dumping database '$PG_DB' (user '$PG_USER') from container '$CONTAINER'..."
docker exec "$CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --format=custom > "$OUT_FILE"

SIZE="$(stat -c%s "$OUT_FILE" 2>/dev/null || stat -f%z "$OUT_FILE")"
if [ "$SIZE" -eq 0 ]; then
    echo "FAIL: backup file is empty: $OUT_FILE" >&2
    rm -f "$OUT_FILE"
    exit 1
fi

echo "Verifying dump integrity (listing contents, no data touched)..."
if ! docker exec -i "$CONTAINER" pg_restore -l < "$OUT_FILE" > /dev/null; then
    echo "FAIL: pg_restore could not read the dump listing — dump looks corrupt." >&2
    exit 1
fi

echo "PASS: backup created and verified -> ${OUT_FILE} (${SIZE} bytes)"
echo "Restore it with: ./restore.sh ${OUT_FILE}"