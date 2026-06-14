#!/usr/bin/env bash

# Print this host's SSH public key and the secrets-blob path derived from it.

set -uo pipefail

CONFIG_FILE="${BOOTC_SECRETS_CONFIG:-/etc/bootc-secrets/config.env}"
HOST_KEY_PATH="${HOST_KEY_PATH:-/etc/ssh/ssh_host_ed25519_key}"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

pub="$HOST_KEY_PATH.pub"

# Generate host keys if the base image's keygen hasn't run yet (idempotent —
# won't touch existing keys), then wait briefly for the public key to appear.
ssh-keygen -A >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    [ -f "$pub" ] && break
    sleep 1
done

if [ ! -f "$pub" ]; then
    echo "show-host-key: $pub not found; SSH host key not generated." >&2
    exit 0
fi

# Same derivation as download_secrets.sh / crypt.sh: OpenSSH SHA256 fingerprint,
# made base64url. This is the bucket path component for this host's blob.
fingerprint="$(ssh-keygen -l -f "$pub" | awk '{print $2}' | sed 's/^SHA256://' | tr '+/' '-_' | tr -d '=')"
base_url="${SECRETS_BASE_URL:-<SECRETS_BASE_URL unset>}"
base_url="${base_url%/}"

cat <<EOF

============== bootc-secrets host identity ==============

  SSH host public key (copy into the secrets repo as host.pub):

$(cat "$pub")

  Secrets blob must exist at:

    ${base_url}/${fingerprint}/secrets

  To re-key after a fresh install, from the secrets repo:

    printf '%s\n' '<the key above>' > host.pub
    AGE_KEY="\$(cat ~/age.key)" vendor/bootc-secrets/crypt.sh --encrypt --upload
    # then on the host: systemctl restart download-secrets.service (or reboot)

========================================================

EOF
