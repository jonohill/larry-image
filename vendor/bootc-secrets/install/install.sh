#!/usr/bin/env bash

# Install the bootc-secrets boot-time decryption tooling.
#
# Works both on a running system and inside a bootc image build (a
# Containerfile RUN step). Installs the `age` binary if missing, drops the
# decryption script and systemd unit into place, and enables the unit.
#
# Prerequisites: curl, jq, tar (curl and tar are also needed at boot).
#
# After install, create /etc/bootc-secrets/config.env with at least:
#   SECRETS_BASE_URL=https://secrets.example.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Install age if not already present.
if ! command -v age >/dev/null 2>&1; then
    case "$(uname -m)" in
        aarch64|arm64) AGE_ARCH=arm64 ;;
        x86_64|amd64)  AGE_ARCH=amd64 ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    LATEST_VERSION="$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/${LATEST_VERSION}/age-${LATEST_VERSION}-linux-${AGE_ARCH}.tar.gz" -o "$tmp/age.tar.gz"
    tar -xzf "$tmp/age.tar.gz" -C "$tmp"
    install -m 0755 "$tmp/age/age" /usr/local/bin/age
    install -m 0755 "$tmp/age/age-keygen" /usr/local/bin/age-keygen
    rm -rf "$tmp"
fi

# 2. Install the decryption script and service unit.
install -m 0755 "$SCRIPT_DIR/download_secrets.sh" /usr/local/sbin/download_secrets.sh
install -m 0644 "$SCRIPT_DIR/download-secrets.service" /etc/systemd/system/download-secrets.service

# 3. Enable it (ordering is a no-op during an image build).
systemctl enable download-secrets.service

echo "Installed. Now create /etc/bootc-secrets/config.env with SECRETS_BASE_URL=<your bucket base url>."
