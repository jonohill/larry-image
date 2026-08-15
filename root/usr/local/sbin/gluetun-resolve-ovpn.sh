#!/bin/bash
set -euo pipefail

SRC=${1:?usage: $0 <source.ovpn> <dest.conf>}
DST=${2:?usage: $0 <source.ovpn> <dest.conf>}

REMOTE_RE='^[[:space:]]*remote[[:space:]]+[^[:space:]]'

candidates=()
while read -r _ host port proto; do
    for ip in $(getent ahostsv4 "$host" | awk '{print $1}' | sort -u); do
        candidates+=("remote $ip ${port:-1194}${proto:+ $proto}")
    done
done < <(grep -Ei "$REMOTE_RE" "$SRC")

if [ ${#candidates[@]} -eq 0 ]; then
    echo "gluetun-resolve-ovpn: no resolvable remote in $SRC" >&2
    exit 1
fi

chosen=${candidates[RANDOM % ${#candidates[@]}]}
echo "gluetun-resolve-ovpn: chose '$chosen' of ${#candidates[@]} candidate(s)" >&2

mkdir -p "$(dirname "$DST")"
umask 077
{
    grep -Eiv "$REMOTE_RE" "$SRC"
    echo "$chosen"
} > "$DST"
