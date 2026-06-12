#!/bin/bash
set -euo pipefail

# ─── config ───────────────────────────────────────────────────────────────────

APP_NAME="gitea"
SERVICE_USER="gitea"
SERVICE_GROUP="gitea"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CREDS="/etc/credstore/$APP_NAME"
APP_INI="/etc/gitea/app.ini"

PASSWORD_CMD="sudo systemd-creds decrypt --name gitea-backup-pass $CREDS/gitea-backup-pass.cred"

# ─── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
die()   { echo "    [error] $*" >&2; exit 1; }

# ─── 1. dependencies ──────────────────────────────────────────────────────────

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
    wget \
    jq \
    restic \
    sqlite3

# yubi

[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
if ! command -v cargo &>/dev/null; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "$HOME/.cargo/env"
fi

if ! ~/.cargo/bin/age-plugin-yubikey --version &>/dev/null 2>&1; then
  cargo install age-plugin-yubikey
fi


# gitea

if [ ! -f gitea ]; then
    wget -O gitea https://dl.gitea.com/gitea/1.26.2/gitea-1.26.2-linux-amd64
    chmod +x gitea
fi

id "$SERVICE_USER" &>/dev/null || sudo adduser \
   --system \
   --shell /bin/bash \
   --gecos 'Git Version Control' \
   --group \
   --disabled-password \
   --home /home/gitea \
   "$SERVICE_USER"

sudo mkdir -p /var/lib/gitea/{custom,data,log}
sudo chmod -R 750 /var/lib/gitea/
sudo mkdir -p /etc/gitea
sudo chmod 770 /etc/gitea

sudo cp gitea /usr/local/bin/gitea

# ─── 2. provision secrets ─────────────────────────────────────────────────────

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

# ─── 3. install backup script ─────────────────────────────────────────────────

info "Installing backup script..."
sudo cp "$SCRIPT_DIR/bin/gitea-backup.sh" /usr/local/sbin/gitea-backup
sudo chmod +x /usr/local/sbin/gitea-backup

sudo mkdir -p "/var/cache/$APP_NAME"
sudo chown "$SERVICE_USER" "/var/cache/$APP_NAME"

# ─── 4. install systemd units ─────────────────────────────────────────────────

info "Installing systemd units..."
sudo cp "$SCRIPT_DIR/systemd/gitea-backup.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/gitea-backup.timer"   /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/gitea.service"        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gitea-backup.timer

# ─── 5. restore from backup if no data present ────────────────────────────────

APP_INI="/etc/gitea/app.ini"
DB_PATH="/var/lib/gitea/data/gitea.db"
DATA_PATH="/var/lib/gitea/data"

if [[ -f "$DB_PATH" ]]; then
    info "Database found at $DB_PATH, skipping restore."
    sudo systemctl restart gitea
    exit 0
fi

info "No database found — attempting restore from backup..."

# ── Temporary workspace ────────────────────────────────────────
TMPDIR=$(mktemp -d -t gitea-restore-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Restore SQLite dump ───────────────────────────────────────────────────────
RESTIC_REPO=$(sudo systemd-creds decrypt --name gitea-backup-url /etc/credstore/gitea/gitea-backup-url.cred)

SNAPSHOT=$(restic -r "$RESTIC_REPO" \
    --password-command "$PASSWORD_CMD" \
    snapshots --json 2>/dev/null | \
    jq -r 'max_by(.time) | .short_id')

DUMP_PATH=$(restic -r "$RESTIC_REPO" \
    --password-command "$PASSWORD_CMD" \
    ls --json "$SNAPSHOT" 2>/dev/null \
    | jq -r 'select(.name == "gitea.sql") | .path' \
    | head -1)

[[ -z "$DUMP_PATH" ]] && die "gitea.sql not found in snapshot $SNAPSHOT."

restic -r "$RESTIC_REPO" \
    --password-command "$PASSWORD_CMD" \
    restore "$SNAPSHOT" \
    --target "$TMPDIR" \
    --path "$DUMP_PATH"

RESTORED_DUMP="$TMPDIR/$DUMP_PATH"
[[ ! -f "$RESTORED_DUMP" ]] && die "Restored SQL dump not found at expected path."

sudo rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
sudo mkdir -p "$(dirname "$DB_PATH")"
sudo sqlite3 "$DB_PATH" < "$RESTORED_DUMP"
sudo chown "$SERVICE_USER" "$DB_PATH"
sudo chmod 600 "$DB_PATH"
info "Database restored."

# ── Restore data directory and app.ini ────────────────────────────────────────
sudo restic -r "$RESTIC_REPO" \
    --password-command "$PASSWORD_CMD" \
    restore "$SNAPSHOT" \
    --target / \
    --path "$DATA_PATH" \
    --path "$APP_INI"

sudo chown -R "$SERVICE_USER" "$DATA_PATH"
sudo chown "$SERVICE_USER" -R /etc/gitea
sudo chown -R "$SERVICE_USER":"$SERVICE_GROUP" /var/lib/gitea

sudo systemctl restart gitea
info "Restore complete."

# ─── backups ──────────────────────────────────────────────────────────────────

BACKUP_BIN="/usr/local/sbin"
sudo cp "$SCRIPT_DIR/bin/$APP_NAME-backup.sh" "$BACKUP_BIN"
sudo chmod +x "$BACKUP_BIN/$APP_NAME-backup.sh"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/"
