#!/bin/bash

# Boot-time secret retrieval and decryption.
#
# Downloads the host's single encrypted blob over plain HTTP(S) from a
# public-read object store, decrypts it with the host's private key, and
# unpacks the plaintext into /run (tmpfs — cleared on reboot).
#
# The blob lives at:
#   $SECRETS_BASE_URL/<host-key-fingerprint>/secrets
# where <host-key-fingerprint> is OpenSSH's SHA256 fingerprint of this host's
# public key, made base64url (see ssh_fingerprint below). The crypt.sh
# --upload step writes to exactly this path, so the two always agree.
#
# Configuration is read at runtime from $BOOTC_SECRETS_CONFIG (default
# /etc/bootc-secrets/config.env). This keeps the script identical across
# every host; only the config file differs.
#
#   SECRETS_BASE_URL  Required. Base URL of the bucket, e.g.
#                     https://secrets.example.com or http://host:9000/bucket.
#                     The fingerprint and "/secrets" are appended.
#   HOST_KEY_PATH     Optional. age identity (the SSH host private key) used
#                     for decryption and to derive the fingerprint.
#                     Default: /etc/ssh/ssh_host_ed25519_key

set -euo pipefail

CONFIG_FILE="${BOOTC_SECRETS_CONFIG:-/etc/bootc-secrets/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

: "${SECRETS_BASE_URL:?SECRETS_BASE_URL must be set in $CONFIG_FILE or the environment}"
HOST_KEY_PATH="${HOST_KEY_PATH:-/etc/ssh/ssh_host_ed25519_key}"

# Path-safe identifier for this host: OpenSSH's SHA256 fingerprint, made
# base64url. ssh-keygen reads the public fingerprint straight from the private
# key, and it is independent of the key's comment/whitespace, so it matches
# whatever crypt.sh computed from host.pub.
fingerprint="$(ssh-keygen -l -f "$HOST_KEY_PATH" | awk '{print $2}' | sed 's/^SHA256://' | tr '+/' '-_' | tr -d '=')"

# Trim any trailing slash from the base URL so we build a clean path.
base_url="${SECRETS_BASE_URL%/}"
url="$base_url/$fingerprint/secrets"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSL "$url" -o "$tmp_dir/secrets.age"

# Decrypt the blob to a tar.gz, then unpack it into /run.
age --decrypt --identity "$HOST_KEY_PATH" \
    --output "$tmp_dir/secrets.tar.gz" \
    "$tmp_dir/secrets.age"
tar -xzf "$tmp_dir/secrets.tar.gz" -C /run

# Tighten permissions on everything we just extracted: 700 dirs, 600 files.
tar -tzf "$tmp_dir/secrets.tar.gz" | while IFS= read -r entry; do
    target="/run/$entry"
    if [ -d "$target" ]; then
        chmod 700 "$target"
    elif [ -f "$target" ]; then
        chmod 600 "$target"
    fi
done
