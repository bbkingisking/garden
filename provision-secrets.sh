#!/bin/bash
# provision-secrets.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

export PASSAGE_DIR="$REPO_ROOT/secrets/store"
export PASSAGE_IDENTITIES_FILE="$REPO_ROOT/secrets/identities"

# Find all age-encrypted files in the passage store
find "$PASSAGE_DIR" -type f -name "*.age" | while read -r age_file; do
    # Get relative path from passage store
    rel_path="${age_file#$PASSAGE_DIR/}"
    
    # Strip .age extension to get passage path
    passage_path="${rel_path%.age}"
    
    # Build the .cred file path
    cred_file="$REPO_ROOT/${passage_path}.cred"
    cred_name="$(basename "$passage_path")"
    
    echo "Provisioning $passage_path -> $cred_file"
    
    # Create directory if needed
    mkdir -p "$(dirname "$cred_file")"
    
    # Read from passage, encrypt with TPM2
    passage show "$passage_path" | \
        systemd-creds encrypt --with-key=tpm2 --name="$cred_name" - "$cred_file"
done

echo "All secrets provisioned successfully!"
