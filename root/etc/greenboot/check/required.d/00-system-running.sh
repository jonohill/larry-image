#!/usr/bin/env bash
# greenboot required health check: fail if any unit has failed once boot has
# settled.
set -uo pipefail

# Transient units podman starts for container health checks. A check that runs
# while a container is still starting fails, and the unit stays failed.
IGNORE='^[0-9a-f]{64}-[0-9a-f]+\.service$'

# Boot has settled when no job is running except this one. Everything still
# queued is then waiting on greenboot.
deadline=$((SECONDS + 900))
while systemctl list-jobs --no-legend --plain \
        | awk '$4 == "running" && $2 != "greenboot-healthcheck.service"' | grep -q .; do
    if (( SECONDS > deadline )); then
        echo "Boot did not settle in 15 minutes; running jobs:" >&2
        systemctl list-jobs --no-legend --plain >&2
        exit 1
    fi
    sleep 5
done

failed_units() {
    systemctl list-units --state=failed --no-legend --plain | awk '{print $1}' | grep -Ev "$IGNORE"
}

# Restart=always units can be failed at the moment boot settles. Give them
# 60 s to come back.
for i in 0 1 2 3 4 5 6; do
    failed="$(failed_units)"
    if [ -z "$failed" ]; then
        echo "System healthy after $((i * 10)) s settle."
        exit 0
    fi
    (( i < 6 )) && sleep 10
done

echo "Failed units: $(echo $failed)" >&2
exit 1
