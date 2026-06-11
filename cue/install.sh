#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="cue"
SERVICE_USER="cue"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/cue.git"
BINARY_DEST="/usr/local/bin"

XDG_CONFIG_HOME="/etc"
XDG_DATA_HOME="/var/lib"
CREDS="/etc/credstore/$APP_NAME"

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

REPO_DIR="$HOME/src/cue"
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
sudo cp "./target/release/cue" "$BINARY_DEST"

sudo chmod +x "$BINARY_DEST/$APP_NAME"

sudo cp "$SCRIPT_DIR/bin/cue_notify.sh" "$BINARY_DEST"
sudo chmod +x "$BINARY_DEST/cue_notify.sh"

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

sudo mkdir -p "$XDG_DATA_HOME/$APP_NAME"
sudo chown -R "$SERVICE_USER" "$XDG_DATA_HOME/$APP_NAME"

# ─── 5. install systemd unit and timer ───────────────────────────────────────

sudo cp "$SCRIPT_DIR/systemd/cue.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/cue.timer"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cue.timer
