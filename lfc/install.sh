#!/bin/bash
set -eo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="lfc"
SERVICE_USER="lfc"
CREDS_GROUP="tss"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/lfc.git"
BINARY_DEST="/usr/local/bin"

XDG_CONFIG_HOME="/etc"
XDG_DATA_HOME="/var/lib"
CREDS="/etc/credstore"

DB_PATH="/var/lib/lfc/articles.db"
RESTIC_REPO="rclone:pcloud:lfc"
PASSWORD_CMD="systemd-creds decrypt --name lfc-db-backup $CREDS/lfc-db-backup.cred"

# ─── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "    [warn] $*"; }
die()   { echo "    [error] $*" >&2; exit 1; }

# ─── 1. dependency check ──────────────────────────────────────────────────────

info "Checking dependencies..."
deps=(git cargo systemd-creds)
for cmd in "${deps[@]}"; do
  command -v "$cmd" &>/dev/null || die "$cmd not found"
done

# ─── 2. service user ──────────────────────────────────────────────────────────

if id "$SERVICE_USER" &>/dev/null; then
  info "User '$SERVICE_USER' already exists, skipping."
else
  info "Creating user '$SERVICE_USER'..."
  sudo useradd -M -s /usr/sbin/nologin -G "$CREDS_GROUP" "$SERVICE_USER"
fi

# ─── 3. compile ───────────────────────────────────────────────────────────────

info "Cloning source code..."
TEMP_DIR="$(mktemp -d)"
git clone "$SOURCE_CODE" "$TEMP_DIR"
cd "$TEMP_DIR"

info "Compiling binary..."
cargo build --release
sudo cp "./target/release/lfc" "$BINARY_DEST"
sudo rm -rf "$TEMP_DIR"

sudo chmod +x "$BINARY_DEST/$APP_NAME"

sudo cp "$SCRIPT_DIR/bin/lfc.sh" "$BINARY_DEST"
sudo chmod +x "$BINARY_DEST/lfc.sh"

# ─── 4. move config and secrets ───────────────────────────────────────────────

sudo mkdir -p "$XDG_CONFIG_HOME/$APP_NAME"
for config_file in "$SCRIPT_DIR/config"/*; do
    [ -f "$config_file" ] || continue  # Skip if no files or directories
    filename=$(basename "$config_file")
    sudo cp "$config_file" "$XDG_CONFIG_HOME/$APP_NAME"
    sudo chown "$SERVICE_USER" "$XDG_CONFIG_HOME/$APP_NAME/$filename"
    sudo chmod 600 "$XDG_CONFIG_HOME/$APP_NAME/$filename"
done

sudo chown -R "$SERVICE_USER" "$XDG_CONFIG_HOME/$APP_NAME"

sudo mkdir -p "$XDG_DATA_HOME/$APP_NAME"
sudo chown -R "$SERVICE_USER" "$XDG_DATA_HOME/$APP_NAME"

sudo mkdir -p "$CREDS"
for cred_file in "$SCRIPT_DIR/secrets"/*.cred; do
    [ -f "$cred_file" ] || continue  # Skip if no .cred files found
    filename=$(basename "$cred_file")
    sudo cp "$cred_file" "$CREDS"
    sudo chown "$SERVICE_USER" "$CREDS/$filename"
    sudo chmod 600 "$CREDS/$filename"
done

# Specifically for lfc, the db backup password is 444 because the backup user
# needs to be able to read it as well and groups are unnecessary complexity
sudo chmod 444 "$CREDS/lfc-db-backup.cred"

# ─── 5. set up cron ───────────────────────────────────────────────────────────

sudo crontab -u "$SERVICE_USER" "$SCRIPT_DIR/crontab/crontab.txt"

# ─── 6. set up db ─────────────────────────────────────────────────────────────

#!/bin/bash
set -euo pipefail

# ── Check if database already exists ───────────────────────────
if [[ -f "$DB_PATH" ]]; then
    sudo chmod 644 "$DB_PATH"
    exit 0
fi

# ── Pre‑checks ─────────────────────────────────────────────────
if ! command -v sqlite3 &>/dev/null; then
    die "ERROR: sqlite3 is required but not installed." >&2
    exit 1
fi

# ── Temporary workspace ────────────────────────────────────────
TMPDIR=$(mktemp -d -t lfc-restore-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Get latest snapshot ────────────────────────────────────────
SNAPSHOT=$(restic -r "$RESTIC_REPO" \
                 --password-command "$PASSWORD_CMD" \
                 snapshots --json 2>/dev/null | \
           jq -r 'max_by(.time) | .short_id')

if [[ -z "$SNAPSHOT" ]]; then
    die "ERROR: No snapshots found." >&2
    exit 1
fi

echo "Restoring from snapshot: $SNAPSHOT"

# ── Restore from restic ────────────────────────────────────────
restic -r "$RESTIC_REPO" \
       --password-command "$PASSWORD_CMD" \
       restore "$SNAPSHOT" \
       --target "$TMPDIR" \
       --path "/articles.db.dump"

# Find the restored file
RESTORED_DUMP=$(find "$TMPDIR" -name "articles.db.dump" -type f)
if [[ -z "$RESTORED_DUMP" ]]; then
    die "ERROR: Restored dump file not found." >&2
    exit 1
fi

# ── Rebuild database with proper permissions ───────────────────
sudo mkdir -p "$(dirname "$DB_PATH")"
sudo sqlite3 "$DB_PATH" < "$RESTORED_DUMP"
sudo chown "$SERVICE_USER" "$DB_PATH"
sudo chmod 644 "$DB_PATH"

echo "Database restored successfully."
