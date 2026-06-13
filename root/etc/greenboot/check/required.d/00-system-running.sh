#!/usr/bin/env bash
# greenboot required health check.
#
set -uo pipefail

# Block until systemd has finished starting (no longer "starting"), then report:
# "running" => exit 0, "degraded" => non-zero.
if systemctl is-system-running --wait >/dev/null 2>&1; then
    echo "System healthy: no failed units."
    exit 0
fi

# Restart=always workloads can be momentarily failed at the instant boot
# finishes; give them a short grace period to recover before condemning the
# deployment.
for i in 1 2 3 4 5 6; do
    sleep 10
    if [ "$(systemctl is-system-running 2>/dev/null)" = "running" ]; then
        echo "System healthy after $((i * 10))s settle."
        exit 0
    fi
done

failed="$(systemctl list-units --state=failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
echo "System degraded; failed units: ${failed:-unknown}" >&2
exit 1
