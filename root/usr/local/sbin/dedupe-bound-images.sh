#!/bin/bash
# Work around a bootc bug: `bootc upgrade` prunes stale bound images by ID via
# `podman rmi` without --force, which fails if the ID carries more than one tag
# (happens when two published tags are byte-identical, e.g. a version bump that
# didn't change the image). Untag such duplicates before the upgrade runs; any
# tag that's still wanted is re-fetched by bootc during staging.
#
# Only fully-stale IDs are touched: if any of an ID's tags is referenced by a
# quadlet Image= line in ANY deployment (booted, staged, or rollback — matching
# the reference semantics of bootc's own prune), the whole ID is left alone.
# Deployments' bound-images.d symlinks are absolute so can't be followed from
# outside that deployment; grep each deployment's quadlet tree directly.
set -euo pipefail

STORE_ROOT=/sysroot/ostree/bootc/storage
RUN_ROOT=/run/bootc/storage
CONF=/run/bootc-dedupe-podman.conf

pod() {
    CONTAINERS_CONF="$CONF" podman --root "$STORE_ROOT" --runroot "$RUN_ROOT" "$@"
}

# The LBI store's libpod db records its static dir as the runroot path.
printf '[engine]\nstatic_dir="%s/libpod"\n' "$RUN_ROOT" > "$CONF"

dup_ids=$(pod images --format '{{.Id}}' | sort | uniq -d)
[ -z "$dup_ids" ] && exit 0

referenced=$(grep -rh '^Image=' \
    /usr/share/containers/systemd \
    /sysroot/ostree/deploy/*/deploy/*/usr/share/containers/systemd \
    --include '*.container' | cut -d= -f2- | sort -u || true)

remounted=
for id in $dup_ids; do
    names=$(pod images --format '{{.Repository}}:{{.Tag}}' --filter "id=$id")
    for name in $names; do
        if grep -qxF "$name" <<< "$referenced"; then
            echo "dedupe-bound-images: $id has referenced tag $name, skipping" >&2
            continue 2
        fi
    done
    if [ -z "$remounted" ]; then
        mount -o remount,rw /sysroot
        remounted=1
    fi
    for name in $names; do
        echo "dedupe-bound-images: untagging $name from $id" >&2
        pod untag "$id" "$name"
    done
done

# Often busy while containers hold overlay mounts; bootc remounts as needed
# and a reboot restores ro, so best-effort only.
[ -n "$remounted" ] && mount -o remount,ro /sysroot || true
