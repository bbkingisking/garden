#!/bin/bash
set -euo pipefail

# metadata
APP_NAME="dragon"

# paths to be backed up
STATIC_PATH="/srv/dragon/static"
DB_PATH="/var/lib/dragon/db.sqlite3"

# make sure the systemd service that calls this has PrivateTmp=true
# so we get trap rm -rf and collision avoidance for free.
SQLITE_DUMP_FILE="/tmp/$APP_NAME.sql"

# txt dumps diff more meaningfully than binary formats, good for daily backups
sqlite3 -readonly "$DB_PATH" ".output $SQLITE_DUMP_FILE" .dump

# --no-cache because cache dirs are unreliable in limited environments
restic --no-cache --compression max backup "$STATIC_PATH" "$SQLITE_DUMP_FILE"

restic -q forget --prune \
    --keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2

restic check
