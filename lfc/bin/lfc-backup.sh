#!/bin/bash
set -euo pipefail

DB_PATH="/var/lib/lfc/articles.db"
DB_STEM=$(basename "${DB_PATH%.db}")

# RESTIC_REPOSITORY_FILE and RESTIC_PASSWORD_FILE already set by the unit;
# no -r or --password-command flags needed here
sqlite3 -readonly "$DB_PATH" .dump | restic -q --no-cache --compression max backup \
    --stdin \
    --stdin-filename "${DB_STEM}.sql"

restic -q forget --prune \
    --keep-last    3 \
    --keep-daily   7 \
    --keep-weekly  4 \
    --keep-monthly 6 \
    --keep-yearly  2
