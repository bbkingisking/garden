#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="dragon"
SERVICE_USER="publius"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

FRONTEND_SOURCE_CODE="https://github.com/longhousepress/frontend"
BACKEND_SOURCE_CODE="https://github.com/longhousepress/backend"

SOURCE_CODE_LOCAL_DIR="$HOME/src/$APP_NAME"
BACKEND_LOCAL_DIR="$SOURCE_CODE_LOCAL_DIR/backend"
FRONTEND_LOCAL_DIR="$SOURCE_CODE_LOCAL_DIR/frontend"

BINARY_DEST="/usr/local/bin"

CONFIG_DEST="/etc/dragon"
DATA_DIR="/var/lib/dragon"
STATIC_DIR="/srv/dragon/static"
PUBLIC_DIR="/srv/dragon/public"
TEMPLATES_DIR="/srv/dragon/templates"
CREDS="/etc/credstore/$APP_NAME"

DB_PATH="$DATA_DIR/db.sqlite3"

# ─── helpers ──────────────────────────────────────────────────────────────────

info() { echo "==> $*"; }
warn() { echo "    [warn] $*"; }
die()  { echo "    [error] $*" >&2; exit 1; }

# ─── 1. dependency provisioning ───────────────────────────────────────────────

info "Installing dependencies..."

sudo apt install -y software-properties-common
sudo add-apt-repository universe -y --no-update
sudo apt update

sudo apt install -y \
    git \
    curl \
    age \
    restic \
    build-essential \
    libssl-dev \
    pkg-config \
    pkgconf \
    libpcsclite-dev \
    pcscd \
    tpm2-tools \
    sqlite3

[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
if ! command -v cargo &>/dev/null; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "$HOME/.cargo/env"
fi

if ! command -v age-plugin-yubikey &>/dev/null; then
    cargo install age-plugin-yubikey
fi

# ─── 2. service user ──────────────────────────────────────────────────────────

if id "$SERVICE_USER" &>/dev/null; then
    info "User '$SERVICE_USER' already exists, skipping."
else
    info "Creating user '$SERVICE_USER'..."
    sudo useradd -M -s /usr/sbin/nologin "$SERVICE_USER"
fi

# ─── 3. compile backend ───────────────────────────────────────────────────────────────

if [ ! -d "$SOURCE_CODE_LOCAL_DIR" ]; then
    sudo mkdir -p "$SOURCE_CODE_LOCAL_DIR"
    sudo chown "$USER" "$SOURCE_CODE_LOCAL_DIR"
fi

cd "$SOURCE_CODE_LOCAL_DIR"

if [ ! -d "$BACKEND_LOCAL_DIR" ]; then
    git clone "$BACKEND_SOURCE_CODE"
fi

cd "$BACKEND_LOCAL_DIR"
git pull
cargo build -q --release

if ! cmp -s "$BACKEND_LOCAL_DIR/target/release/backend" "$BINARY_DEST/$APP_NAME"; then
    sudo mv "$BACKEND_LOCAL_DIR/target/release/backend" "$BINARY_DEST/$APP_NAME"
    sudo chmod +x "$BINARY_DEST/$APP_NAME"
fi


# ─── 4. directories ───────────────────────────────────────────────────────────

info "Setting up directories..."
sudo mkdir -p "$CONFIG_DEST" "$DATA_DIR" "$STATIC_DIR" "$PUBLIC_DIR" "$TEMPLATES_DIR"

sudo chown -R "$SERVICE_USER" "$CONFIG_DEST" "$DATA_DIR" "/srv/dragon"
sudo chmod 700 "$CONFIG_DEST"
sudo chmod -R 775 "$DATA_DIR" "$STATIC_DIR" "$PUBLIC_DIR" "$TEMPLATES_DIR"

# ─── 5. config file ───────────────────────────────────────────────────────────

info "Installing config..."
sudo cp "$SCRIPT_DIR/config/config" "$CONFIG_DEST/config"
sudo chown "$SERVICE_USER" "$CONFIG_DEST/config"
sudo chmod 600 "$CONFIG_DEST/config"

# ─── 6. templates ─────────────────────────────────────────────────────────────

info "Installing templates..."
sudo cp -r "$BACKEND_LOCAL_DIR/templates/." "$TEMPLATES_DIR/"
sudo chown -R "$SERVICE_USER:root" "$TEMPLATES_DIR"
sudo find "$TEMPLATES_DIR" -maxdepth 1 -type f -exec chmod 400 {} +
sudo chmod 500 "$TEMPLATES_DIR"

# ─── 7. credentials ───────────────────────────────────────────────────────────

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
        sudo chmod 400 "$cred_file"
    fi
done

# ─── 8. systemd service ───────────────────────────────────────────────────────

if [[ -f "/etc/systemd/system/$APP_NAME.service" ]] \
   && cmp -s "$SCRIPT_DIR/$APP_NAME.service" "/etc/systemd/system/$APP_NAME.service"; then
    info "Service already installed and up to date, skipping."
else
    info "Installing systemd service..."
    sudo cp "$SCRIPT_DIR/systemd/$APP_NAME.service" "/etc/systemd/system/$APP_NAME.service"
    sudo systemctl daemon-reload
    sudo systemctl enable "$APP_NAME"
fi

# ─── 9. database and static restore ──────────────────────────────────────────

RESTIC_REPO=$(sudo systemd-creds decrypt --name dragon-backup-url "$CREDS/dragon-backup-url.cred")
PASSWORD_CMD="sudo systemd-creds decrypt --name dragon-backup-pass $CREDS/dragon-backup-pass.cred"

if [[ -f "$DB_PATH" ]]; then
    info "Database found at $DB_PATH, skipping restore."
else
    info "Restoring from restic backup..."
    RESTORE_TMP=$(mktemp -d)
    trap 'rm -rf "$RESTORE_TMP"' EXIT

    restic -r "$RESTIC_REPO" --password-command "$PASSWORD_CMD" restore latest --target "$RESTORE_TMP"

    DUMP_FILE=$(find "$RESTORE_TMP" -name "$APP_NAME.sql" -type f)
    [[ -n "$DUMP_FILE" ]] || die "$APP_NAME.sql not found in backup"

    sudo sqlite3 "$DB_PATH" < "$DUMP_FILE"
    sudo chown -R "$SERVICE_USER" "$DB_PATH"
    sudo chmod 770 -R "$DB_PATH"

    sudo cp -r "$RESTORE_TMP/$STATIC_DIR/." "$STATIC_DIR/"
    sudo chown -R "$SERVICE_USER" "$STATIC_DIR"

    rm -rf "$RESTORE_TMP"
    info "Restore complete."
fi

sudo systemctl restart "$APP_NAME"
info "Done. Use 'sudo systemctl status $APP_NAME' to verify."

# --- 7. build frontend

# install pnpm
cd "$SOURCE_CODE_LOCAL_DIR"

if [ ! -d node-v26.3.0-linux-x64 ]; then
    curl -O "https://nodejs.org/dist/v26.3.0/node-v26.3.0-linux-x64.tar.xz"
    tar xf node-v26.3.0-linux-x64.tar.xz
fi

# use absolute paths to avoid env issues
export PATH="$SOURCE_CODE_LOCAL_DIR/node-v26.3.0-linux-x64/bin:$PATH"

if [ ! -d "$FRONTEND_LOCAL_DIR" ]; then
    git clone "$FRONTEND_SOURCE_CODE"
fi

cd "$FRONTEND_LOCAL_DIR"
git pull

npm install
OUT_DIR=./dist npm run build:prod --emptyOutDir
sudo cp -r dist/* /srv/dragon/public

# ─── 10. backups ─────────────────────────────────────────────────────────────

BACKUP_BIN="/usr/local/sbin"
sudo cp "$SCRIPT_DIR/bin/$APP_NAME-backup.sh" "$BACKUP_BIN"
sudo chmod +x "$BACKUP_BIN/$APP_NAME-backup.sh"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/"
