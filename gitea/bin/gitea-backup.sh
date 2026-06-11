#!/bin/bash
set -euo pipefail

APP_INI="/etc/gitea/app.ini"
DB_PATH="/var/lib/gitea/data/gitea.db"
DATA_PATH="/var/lib/gitea/data"

# ─── 1. SQLite online backup ──────────────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

sqlite3 "$DB_PATH" ".output $TEMP_DIR/gitea.sql" .dump

# ─── 2. Clear any stale lock, then back up ────────────────────────────────────
restic -q unlock 2>/dev/null || true

restic --no-cache --compression max backup \
    "$APP_INI" \
    "$TEMP_DIR/gitea.sql" \
    "$DATA_PATH" \
    --exclude "$DB_PATH" \
    --exclude "$DATA_PATH/sessions"

# ─── 3. Prune ─────────────────────────────────────────────────────────────────
restic -q forget --prune \
    --keep-last    3 \
    --keep-daily   7 \
    --keep-weekly  4 \
    --keep-monthly 6 \
    --keep-yearly  2
