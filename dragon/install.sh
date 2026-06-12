#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="dragon"
SERVICE_USER="publius"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BINARY_DEST="/usr/local/bin"

CONFIG_DEST="/etc/dragon"
DATA_DIR="/var/lib/dragon"
STATIC_DIR="/srv/dragon/static"
PUBLIC_DIR="/srv/dragon/public"
TEMPLATES_DIR="/srv/dragon/templates"
CREDS="/etc/credstore/$APP_NAME"

DB_PATH="$DATA_DIR/db.sqlite3"

SECRETS=(
    token_key
    stripe_api_key
    stripe_webhook_secret
    resend_api_key
    submissions_to_email
    database_url
    restic_password
)

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

# ─── 3. compile ───────────────────────────────────────────────────────────────

info "Compiling binary..."
cd "$REPO_DIR"
cargo build --release
if [[ "./target/release/backend" -ef "$BINARY_DEST/$APP_NAME" ]]; then
    info "Binary already in place, skipping."
else
    sudo mv "./target/release/backend" "$BINARY_DEST/$APP_NAME"
    sudo chmod +x "$BINARY_DEST/$APP_NAME"
fi
cd "$SCRIPT_DIR"

# ─── 4. directories ───────────────────────────────────────────────────────────

info "Setting up directories..."
for dir in "$CONFIG_DEST" "$DATA_DIR" "$STATIC_DIR" "$PUBLIC_DIR" "$TEMPLATES_DIR"; do
    sudo mkdir -p "$dir"
done

sudo chown -R "$SERVICE_USER" "$CONFIG_DEST"
sudo chown -R "$SERVICE_USER" "$DATA_DIR"
sudo chown -R "$SERVICE_USER" /srv/dragon
sudo chmod 700 "$CONFIG_DEST"
sudo chmod -R 770 "$DATA_DIR" "$STATIC_DIR" "$PUBLIC_DIR" "$TEMPLATES_DIR"

# ─── 5. config file ───────────────────────────────────────────────────────────

info "Installing config..."
sudo cp "$SCRIPT_DIR/config/config" "$CONFIG_DEST/config"
sudo chown "$SERVICE_USER" "$CONFIG_DEST/config"
sudo chmod 600 "$CONFIG_DEST/config"

# ─── 6. templates ─────────────────────────────────────────────────────────────

info "Installing templates..."
sudo cp -r "$REPO_DIR/templates/." "$TEMPLATES_DIR/"
sudo chown -R "$SERVICE_USER:root" "$TEMPLATES_DIR"
sudo find "$TEMPLATES_DIR" -maxdepth 1 -type f -exec chmod 400 {} +
sudo chmod 500 "$TEMPLATES_DIR"

# ─── 7. credentials ───────────────────────────────────────────────────────────

sudo mkdir -p "$CREDS"

all_creds_exist=true
for name in "${SECRETS[@]}"; do
    [[ -f "$CREDS/dragon-$name.cred" ]] || { all_creds_exist=false; break; }
done

if $all_creds_exist; then
    info "All credentials already exist, skipping."
else
    info "Encrypting credentials (YubiKey required)..."
    for name in "${SECRETS[@]}"; do
        target="$CREDS/dragon-$name.cred"
        if [[ -f "$target" ]]; then
            info "  $name already exists, skipping."
            continue
        fi
        info "  Encrypting $name..."
        age -d -i "$SCRIPT_DIR/secrets/identities" "$SCRIPT_DIR/secrets/$name.age" \
            | sudo systemd-creds encrypt --tpm2-device=auto --name="dragon-$name" - "$target"
        sudo chown "$SERVICE_USER" "$target"
        sudo chmod 400 "$target"
    done
fi

# ─── 8. systemd service ───────────────────────────────────────────────────────

if [[ -f "/etc/systemd/system/$APP_NAME.service" ]] \
   && cmp -s "$SCRIPT_DIR/$APP_NAME.service" "/etc/systemd/system/$APP_NAME.service"; then
    info "Service already installed and up to date, skipping."
else
    info "Installing systemd service..."
    sudo cp "$SCRIPT_DIR/systemd/$APP_NAME.service" "/etc/systemd/system/$APP_NAME.service"
    sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/$APP_NAME-backup.service"
    sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/$APP_NAME-backup.timer"
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
