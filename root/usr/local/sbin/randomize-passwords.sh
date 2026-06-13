#!/usr/bin/env bash

set -euo pipefail

users=(root jono)

for user in "${users[@]}"; do
    home="$(getent passwd "$user" | cut -d: -f6)"
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        echo "no home directory for $user; skipping" >&2
        continue
    fi

    # 32 chars from /dev/urandom.
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    printf '%s:%s\n' "$user" "$pw" | chpasswd

    # Write the password to a file only the owning user can read.
    pw_file="$home/.initial-password"
    ( umask 077; printf '%s\n' "$pw" > "$pw_file" )
    chown "$user:" "$pw_file"
    chmod 0400 "$pw_file"

    echo "randomized password for $user (written to $pw_file)"
done
