#!/bin/bash
set -eo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="cue"
SERVICE_USER="cue"
CREDS_GROUP="tss"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/cue.git"
BINARY_DEST="/usr/local/bin"

XDG_CONFIG_DIR="/etc/"
CREDS="/etc/credstore/"

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
sudo cp "./target/release/cue" "$BINARY_DEST"
sudo rm -rf "$TEMP_DIR"

sudo chmod +x "$BINARY_DEST/$APP_NAME"

sudo cp "$SCRIPT_DIR/bin/cue_notify.sh" "$BINARY_DEST"
sudo chmod +x "$BINARY_DEST/cue_notify.sh"

# ─── 4. move config and secrets ───────────────────────────────────────────────

sudo mkdir -p "$XDG_CONFIG_DIR/$APP_NAME"
sudo cp "$SCRIPT_DIR/config/config.toml" "$XDG_CONFIG_DIR/$APP_NAME"
sudo chown "$SERVICE_USER" "$XDG_CONFIG_DIR/$APP_NAME/config.toml"
sudo chmod 600 "$XDG_CONFIG_DIR/$APP_NAME/config.toml"

sudo mkdir -p "$CREDS"
sudo cp "$SCRIPT_DIR/secrets/cue-chat-id.cred" "$CREDS"
sudo chown "$SERVICE_USER" "$CREDS/cue-chat-id.cred"
sudo chmod 600 "$CREDS/cue-chat-id.cred"

sudo cp "$SCRIPT_DIR/secrets/cue-notify.cred" "$CREDS"
sudo chown "$SERVICE_USER" "$CREDS/cue-notify.cred"
sudo chmod 600 "$CREDS/cue-notify.cred"

# ─── 5. set up cron ───────────────────────────────────────────────────────────

sudo crontab -u "$SERVICE_USER" "$SCRIPT_DIR/crontab/crontab.txt"

