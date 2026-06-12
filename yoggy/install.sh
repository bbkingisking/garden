APP_NAME="sonnets"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

# ─── backups ──────────────────────────────────────────────────────────────────

BACKUP_BIN="/usr/local/sbin"
sudo cp "$SCRIPT_DIR/bin/$APP_NAME-backup.sh" "$BACKUP_BIN"
sudo chmod +x "$BACKUP_BIN/$APP_NAME-backup.sh"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.service" "/etc/systemd/system/"
sudo cp "$SCRIPT_DIR/systemd/$APP_NAME-backup.timer" "/etc/systemd/system/"
