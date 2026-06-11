#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="herald"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CODE="https://github.com/bbkingisking/herald"
BINARY_DEST="/usr/local/bin"

CREDS="/etc/credstore/$APP_NAME"

# ─── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
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

if id "herald" &>/dev/null; then
    info "User 'herald' already exists, skipping."
else
    info "Creating user 'herald'..."
    sudo useradd -M -s /usr/sbin/nologin -G systemd-journal herald
fi

# ─── 3. compile ───────────────────────────────────────────────────────────────

REPO_DIR="$HOME/src/$APP_NAME"
if [[ ! -d "$REPO_DIR" ]]; then
    info "Cloning source code to $REPO_DIR..."
    mkdir -p "$HOME/src"
    git clone "$SOURCE_CODE" "$REPO_DIR"
fi
cd "$REPO_DIR"
git pull

info "Compiling binary..."
cargo build --release
sudo cp "./target/release/$APP_NAME" "$BINARY_DEST"
sudo chmod +x "$BINARY_DEST/$APP_NAME"

# ─── 4. provision secrets ─────────────────────────────────────────────────────

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
        sudo chmod 400 "$cred_file"
    fi
done

# ─── 5. install systemd unit ──────────────────────────────────────────────────

info "Installing systemd unit..."
sudo cp "$SCRIPT_DIR/systemd/herald@.service" /etc/systemd/system/
sudo systemctl daemon-reload

info "Done. Other services can now use OnFailure=herald@%n in their unit files."
