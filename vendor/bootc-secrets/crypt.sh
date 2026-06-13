#!/usr/bin/env bash

# Encrypt, decrypt, or rotate secrets in a secrets directory, and optionally
# upload the encrypted blob to an S3/R2 bucket.
#
# The whole secrets directory is packed into a
# tar.gz and age-encrypted to ONE binary blob (default: secrets.age).
# It is encrypted to TWO recipients:
#   - your personal age key (derived from $AGE_KEY) — so you can always
#     decrypt/rotate locally
#   - the host's public key (host.pub) — so the host can decrypt itself
#     autonomously at boot (see install/download_secrets.sh)
#
# With --upload the blob is pushed to the object store at
#   s3://$BUCKET/<host-key-fingerprint>/secrets
# where the fingerprint is the host's SSH public key fingerprint (see
# ssh_fingerprint below). The host computes the same path from its own key and
# fetches the blob at boot.
#
# Run this from the root of the repo that owns the secrets, e.g.
#   AGE_KEY="$(cat ~/age.key)" vendor/bootc-secrets/crypt.sh --encrypt --upload

set -euo pipefail

# Directory holding the secrets (one subdirectory per service). Relative to
# the current working directory by default so this works when vendored.
SECRETS_DIR="${SECRETS_DIR:-secrets}"
# Host public key file. The host decrypts using its matching private key.
HOST_PUBKEY_FILE="${HOST_PUBKEY_FILE:-host.pub}"
# Single encrypted output blob (tar.gz of $SECRETS_DIR, age-encrypted).
OUTPUT_FILE="${OUTPUT_FILE:-secrets.age}"

usage() {
    cat << EOF
Usage: $0 [OPTION]...
Pack, encrypt, decrypt, or rotate the secrets directory as a single blob,
and optionally upload it to S3/R2.

Options:
    -e, --encrypt   Pack \$SECRETS_DIR into \$OUTPUT_FILE (tar.gz + age)
    -d, --decrypt   Decrypt \$OUTPUT_FILE and unpack it into \$SECRETS_DIR
    -r, --rotate    Rotate (decrypt then re-encrypt with the current host key)
    -u, --upload    Upload \$OUTPUT_FILE to s3://\$BUCKET/<fingerprint>/secrets
                    (may be combined with --encrypt/--rotate, or used alone to
                    upload an existing \$OUTPUT_FILE)
    -h, --help      Show this help message

Environment Variables:
    AGE_KEY          Required for encrypt/decrypt/rotate. The age private key.
    SECRETS_DIR      Optional. Secrets directory (default: secrets).
    HOST_PUBKEY_FILE Optional. Host public key file (default: host.pub).
    OUTPUT_FILE      Optional. Encrypted blob path (default: secrets.age).

  For --upload (uses the AWS CLI; reads standard AWS credentials from the env):
    BUCKET            Required. Target bucket name.
    AWS_ENDPOINT_URL  Optional. Custom S3 endpoint (e.g. your R2 endpoint).
    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, ...  Standard AWS credentials.

Files:
    \$HOST_PUBKEY_FILE  Required for encrypt/rotate/upload. Lets the host
                       decrypt, and provides the upload path fingerprint.

EOF
}

OPERATION=""
UPLOAD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--encrypt)
            OPERATION="encrypt"
            shift
            ;;
        -d|--decrypt)
            OPERATION="decrypt"
            shift
            ;;
        -r|--rotate)
            OPERATION="rotate"
            shift
            ;;
        -u|--upload)
            UPLOAD=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$OPERATION" ]] && [[ "$UPLOAD" != true ]]; then
    echo "Error: No operation specified. Use -e, -d, -r, and/or -u."
    usage
    exit 1
fi

# AGE_KEY is needed for any crypto operation, but not for a bare --upload.
if [[ -n "$OPERATION" ]] && [[ -z "${AGE_KEY:-}" ]]; then
    echo "Error: AGE_KEY environment variable is not set."
    exit 1
fi

# host.pub is needed to encrypt for the host and to derive the upload path.
if { [[ "$OPERATION" == "encrypt" || "$OPERATION" == "rotate" ]] || [[ "$UPLOAD" == true ]]; } \
    && [[ ! -f "$HOST_PUBKEY_FILE" ]]; then
    echo "Error: host public key '$HOST_PUBKEY_FILE' not found (needed to encrypt for the host / derive the upload path)."
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Path-safe identifier for a host: OpenSSH's SHA256 fingerprint, made
# base64url. Works on either the public or the private key file, and is
# independent of the key's comment/whitespace, so both sides agree.
ssh_fingerprint() {
    ssh-keygen -l -f "$1" | awk '{print $2}' | sed 's/^SHA256://' | tr '+/' '-_' | tr -d '='
}

encrypt() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        echo "Error: secrets directory '$SECRETS_DIR' not found (run from the repo root, or set SECRETS_DIR)."
        exit 1
    fi

    age_key_file="$tmpdir/age.key"
    echo "$AGE_KEY" > "$age_key_file"
    pubkey="$(age-keygen -y "$age_key_file")"

    # Pack the secrets (skip repo metadata) and encrypt to a single binary blob.
    tar -czf - -C "$SECRETS_DIR" \
        --exclude='.gitignore' \
        --exclude='*.md' \
        . \
    | age -e \
        -r "$pubkey" \
        -R "$HOST_PUBKEY_FILE" \
        -o "$OUTPUT_FILE"

    echo "Encrypted $SECRETS_DIR -> $OUTPUT_FILE"
}

decrypt() {
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "Error: encrypted blob '$OUTPUT_FILE' not found."
        exit 1
    fi

    age_key_file="$tmpdir/age.key"
    echo "$AGE_KEY" > "$age_key_file"

    mkdir -p "$SECRETS_DIR"
    age -d -i "$age_key_file" "$OUTPUT_FILE" | tar -xzf - -C "$SECRETS_DIR"

    echo "Decrypted $OUTPUT_FILE -> $SECRETS_DIR"
}

rotate() {
    decrypt
    encrypt
}

upload() {
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "Error: encrypted blob '$OUTPUT_FILE' not found (run --encrypt first)."
        exit 1
    fi
    : "${BUCKET:?BUCKET must be set for --upload}"

    fingerprint="$(ssh_fingerprint "$HOST_PUBKEY_FILE")"
    dest="s3://$BUCKET/$fingerprint/secrets"

    # AWS CLI reads credentials and (optionally) AWS_ENDPOINT_URL from the env.
    endpoint_args=()
    if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
        endpoint_args=(--endpoint-url "$AWS_ENDPOINT_URL")
    fi

    aws s3 cp "${endpoint_args[@]}" "$OUTPUT_FILE" "$dest"
    echo "Uploaded $OUTPUT_FILE -> $dest"
}

case "$OPERATION" in
    "encrypt") encrypt ;;
    "decrypt") decrypt ;;
    "rotate")  rotate ;;
    "")        ;; # bare --upload
esac

if [[ "$UPLOAD" == true ]]; then
    upload
fi
