#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="lfc"
SERVICE_USER="lfc"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/lfc.git"
BINARY_DEST="/usr/local/bin"

XDG_CONFIG_HOME="/etc"
XDG_DATA_HOME="/var/lib"
CREDS="/etc/credstore/$APP_NAME"

DB_PATH="/var/lib/lfc/articles.db"
PASSWORD_CMD="sudo systemd-creds decrypt --name lfc-db-backup $CREDS/lfc-db-backup.cred"

# ─── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "    [warn] $*"; }
die()   { echo "    [error] $*" >&2; exit 1; }

# ─── make sure the garden is up to date ───────────────────────────────────────

cd "$SCRIPT_DIR"
git pull

# ─── 1. dependency provisioning ───────────────────────────────────────────────

info "Installing dependencies..."

sudo apt install -y software-properties-common
sudo add-apt-repository universe -y --no-update
sudo apt update

sudo apt install -y \
    git \
    curl \
    age \
    sqlite3 \
    restic \
    rclone \
    jq \
    build-essential \
    pkg-config \
    libssl-dev \
    libsqlite3-dev \
    tpm2-tools \
    pkgconf \
    libpcsclite-dev

[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
if ! command -v cargo &>/dev/null; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "$HOME/.cargo/env"
fi

# ─── 2. service user ──────────────────────────────────────────────────────────

if id "$SERVICE_USER" &>/dev/null; then
  info "User '$SERVICE_USER' already exists, skipping."
else
  info "Creating user '$SERVICE_USER'..."
  sudo useradd -M -s /usr/sbin/nologin "$SERVICE_USER"
fi

# ─── 3. compile ───────────────────────────────────────────────────────────────

REPO_DIR="$HOME/src/lfc"
if [[ ! -d "$REPO_DIR" ]]; then
    info "Cloning source code to $REPO_DIR..."
    mkdir -p "$HOME/src"
    git clone "$SOURCE_CODE" "$REPO_DIR"
else
    info "Repo already exists, pulling latest..."
    git -C "$REPO_DIR" pull
fi
cd "$REPO_DIR"

info "Compiling binary..."
cargo build --release
sudo cp "./target/release/lfc" "$BINARY_DEST"

sudo chmod +x "$BINARY_DEST/$APP_NAME"

sudo cp "$SCRIPT_DIR/bin/lfc-backup.sh" /usr/local/sbin/lfc-backup
sudo chmod +x /usr/local/sbin/lfc-backup

# ─── 3.5 provision secrets ──────────────────────────────────────────────────

cd "$SCRIPT_DIR"
if ! ~/.cargo/bin/age-plugin-yubikey --version &>/dev/null 2>&1; then
  cargo install age-plugin-yubikey
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IDENTITIES_FILE="$REPO_ROOT/identities"

info "Provisioning secrets..."
sudo mkdir -p "$CREDS"
for age_file in "$SCRIPT_DIR/secrets"/*.age; do
    [ -f "$age_file" ] || continue
    name="$(basename "${age_file%.age}")"
    cred_file="$CREDS/${name}.cred"
    if sudo test -f "$cred_file"; then
        info "  $name.cred already exists, skipping."
    else
        info "  Decrypting $name.age -> $cred_file"
        age -d -i "$IDENTITIES_FILE" "$age_file" | \
            sudo systemd-creds encrypt --with-key=tpm2 --name="$name" - "$cred_file"
        sudo chown "$SERVICE_USER" "$cred_file"
        sudo chmod 400 "$cred_file"
    fi
done

# ─── 4. move config ─────────────────────────────────────────────────────────

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

sudo mkdir -p "/var/cache/$APP_NAME"
sudo chown "$SERVICE_USER" "/var/cache/$APP_NAME"

# ─── 5. install systemd units and timers ─────────────────────────────────────

sudo cp "$SCRIPT_DIR/systemd/lfc.service"        /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/lfc.timer"          /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/lfc-backup.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/lfc-backup.timer"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lfc.timer
sudo systemctl enable --now lfc-backup.timer

# ─── 6. set up db ─────────────────────────────────────────────────────────────

if [[ -f "$DB_PATH" ]]; then
    sudo chmod 600 "$DB_PATH"
    exit 0
fi

RESTIC_REPO=$(sudo systemd-creds decrypt --name lfc-db-url $CREDS/lfc-db-url.cred)

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
       --path "/articles.sql"

# Find the restored file
RESTORED_DUMP=$(find "$TMPDIR" -name "articles.sql" -type f)
if [[ -z "$RESTORED_DUMP" ]]; then
    die "ERROR: Restored dump file not found." >&2
    exit 1
fi

# ── Rebuild database with proper permissions ───────────────────
sudo mkdir -p "$(dirname "$DB_PATH")"
sudo sqlite3 "$DB_PATH" < "$RESTORED_DUMP"
sudo chown "$SERVICE_USER" "$DB_PATH"
sudo chmod 600 "$DB_PATH"

echo "Database restored successfully."

# ─── backups ──────────────────────────────────────────────────────────────────

BACKUP_BIN="/usr/local/sbin"
sudo cp "$SCRIPT_DIR/bin/$APP_NAME-backup.sh" "$BACKUP_BIN"
sudo chmod +x "$BACKUP_BIN/$APP_NAME-backup.sh"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/"
