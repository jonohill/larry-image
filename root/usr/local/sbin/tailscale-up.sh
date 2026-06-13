#!/usr/bin/env bash

set -euo pipefail

# Already on the tailnet? Nothing to do. BackendState is "Running" once up;
# "NeedsLogin"/"Stopped"/"NoState" all mean we should attempt the bootstrap.
state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || true)"
if [ "$state" = "Running" ]; then
    echo "tailscale already up (BackendState=Running); nothing to do."
    exit 0
fi

env_file=/run/tailscale/env
if [ ! -f "$env_file" ]; then
    echo "No $env_file — tailscale bootstrap secret not present; skipping." >&2
    exit 0
fi

# shellcheck disable=SC1090
. "$env_file"
: "${TS_AUTHKEY:?TS_AUTHKEY must be set in $env_file}"

# shellcheck disable=SC2086 - TS_UP_ARGS is intentionally word-split into flags.
exec tailscale up \
    --auth-key="$TS_AUTHKEY" \
    --hostname="$(hostname -s)" \
    --ssh \
    ${TS_UP_ARGS:-}
