#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="hwaiting"
SERVICE_USER="ajussi"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/hwaiting"
BINARY_DEST="/usr/local/bin"
LIB_DEST="/usr/local/lib/$APP_NAME"

XDG_CONFIG_HOME="/etc"
XDG_DATA_HOME="/var/lib"
CREDS="/etc/credstore/$APP_NAME"
STATIC_DIR="/srv/$APP_NAME/dist"
DB_PATH="$XDG_DATA_HOME/$APP_NAME/db/$APP_NAME.sqlite3"

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
    build-essential \
    pkg-config \
    libssl-dev \
    tpm2-tools \
    pkgconf \
    libpcsclite-dev \
    sqlite3 \
    restic \
    rclone \
    jq

# Install Node.js 22 via NodeSource (apt ships an outdated version)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

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

REPO_DIR="$HOME/src/hwaiting"
if [[ ! -d "$REPO_DIR" ]]; then
    info "Cloning source code to $REPO_DIR..."
    mkdir -p "$HOME/src"
    git clone "$SOURCE_CODE" "$REPO_DIR"
else
    info "Repo already exists, pulling latest..."
    git -C "$REPO_DIR" pull
fi
cd "$REPO_DIR"

info "Building frontend..."
cd "$REPO_DIR/frontend"
npm install
VITE_OUT="$REPO_DIR/frontend/dist"
STATIC_DIR="$VITE_OUT" npm run build -- --emptyOutDir

info "Compiling backend..."
cd "$REPO_DIR/backend"
cargo build --release
sudo cp "./target/release/$APP_NAME" "$BINARY_DEST"
sudo chmod +x "$BINARY_DEST/$APP_NAME"

info "Installing frontend static files..."
sudo mkdir -p "$STATIC_DIR"
sudo cp -r "$VITE_OUT/." "$STATIC_DIR/"
sudo chown -R "$SERVICE_USER" "$STATIC_DIR"


info "Installing backup script..."
sudo mkdir -p "$LIB_DEST"
sudo cp "$SCRIPT_DIR/bin/backup.sh" "$LIB_DEST"
sudo chmod +x "$LIB_DEST/backup.sh"

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
    [ -f "$config_file" ] || continue
    filename=$(basename "$config_file")
    sudo cp "$config_file" "$XDG_CONFIG_HOME/$APP_NAME"
    sudo chown "$SERVICE_USER" "$XDG_CONFIG_HOME/$APP_NAME/$filename"
    sudo chmod 600 "$XDG_CONFIG_HOME/$APP_NAME/$filename"
done

sudo chown -R "$SERVICE_USER" "$XDG_CONFIG_HOME/$APP_NAME"

sudo mkdir -p "$XDG_DATA_HOME/$APP_NAME/db"
sudo chown -R "$SERVICE_USER" "$XDG_DATA_HOME/$APP_NAME"

# ─── 5. install systemd units ─────────────────────────────────────────────────

for unit_file in "$SCRIPT_DIR/systemd"/*; do
    [ -f "$unit_file" ] || continue
    sudo cp "$unit_file" /etc/systemd/system/
done

sudo systemctl daemon-reload
sudo systemctl enable "$APP_NAME.service"
sudo systemctl enable --now "$APP_NAME-backup.timer"

# ─── 6. set up db ─────────────────────────────────────────────────────────────

if [[ -f "$DB_PATH" ]]; then
    info "DB found"
    sudo chmod 600 "$DB_PATH"
else
    info "DB not found, attempting to restore from backup"

    RESTIC_REPO=$(sudo systemd-creds decrypt \
        --name=hwaiting-restic_repo "$CREDS/hwaiting-restic_repo.cred" -)
    RESTIC_PASS_CMD="sudo systemd-creds decrypt \
        --name=hwaiting-restic_pass $CREDS/hwaiting-restic_pass.cred -"

    RESTORE_DIR=$(mktemp -d -t hwaiting-restore-XXXXXX)
    trap 'rm -rf "$RESTORE_DIR"' EXIT

    SNAPSHOT=$(restic -r "$RESTIC_REPO" \
                     --password-command "$RESTIC_PASS_CMD" \
                     snapshots --json 2>/dev/null | \
               jq -r 'max_by(.time) | .short_id')

    [[ -z "$SNAPSHOT" ]] && die "No snapshots found."

    info "Restoring from snapshot: $SNAPSHOT"

    restic -r "$RESTIC_REPO" \
           --password-command "$RESTIC_PASS_CMD" \
           restore "$SNAPSHOT" \
           --target "$RESTORE_DIR" \
           --path "/hwaiting.sql"

    RESTORED_DUMP=$(find "$RESTORE_DIR" -name "hwaiting.sql" -type f)
    [[ -z "$RESTORED_DUMP" ]] && die "Restored dump file not found."

    sudo sqlite3 "$DB_PATH" < "$RESTORED_DUMP"
    sudo chown "$SERVICE_USER" "$DB_PATH"
    sudo chmod 600 "$DB_PATH"

    info "Database restored successfully."
fi

sudo systemctl start "$APP_NAME.service"

# ─── backups ──────────────────────────────────────────────────────────────────

BACKUP_BIN="/usr/local/sbin"
sudo cp "$SCRIPT_DIR/bin/$APP_NAME-backup.sh" "$BACKUP_BIN"
sudo chmod +x "$BACKUP_BIN/$APP_NAME-backup.sh"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/"
