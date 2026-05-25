#!/bin/bash
# provision-secrets.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

SECRETS_DIR="$REPO_ROOT/secrets/store"
IDENTITIES_FILE="$REPO_ROOT/secrets/identities"

# Find all age-encrypted files in the store
find "$SECRETS_DIR" -type f -name "*.age" | while read -r age_file; do
    # Get relative path from store
    rel_path="${age_file#$SECRETS_DIR/}"

    # Strip .age extension to get the cred name
    cred_name="${rel_path%.age}"
    cred_name="$(basename "$cred_name")"

    # Build the .cred file path
    cred_file="$REPO_ROOT/${rel_path%.age}.cred"

    echo "Provisioning $rel_path -> $cred_file"

    # Create directory if needed
    mkdir -p "$(dirname "$cred_file")"

    # Decrypt with age, encrypt with TPM2
    age -d -i "$IDENTITIES_FILE" "$age_file" | \
        systemd-creds encrypt --with-key=tpm2 --name="$cred_name" - "$cred_file"
done

echo "All secrets provisioned successfully!"
