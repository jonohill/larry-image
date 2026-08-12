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
SCRATCH=/run/bootc-dedupe-store

# Reads go through a throwaway store on tmpfs with the LBI store attached as an
# *additional* image store. podman takes a write lock on its --root even just to
# list, and /sysroot is read-only outside of an upgrade — but an additional
# image store is opened read-only by design, which is how the quadlets read this
# same store at boot. Getting this wrong wedges the nightly upgrade with
# "open .../storage.lock: read-only file system".
pod_ro() {
    podman --root "$SCRATCH/root" --runroot "$SCRATCH/run" \
        --storage-opt=additionalimagestore="$STORE_ROOT" "$@"
}

# Writes need the real store, and so a writable /sysroot. Only ever reached when
# there is genuinely something to untag.
pod_rw() {
    CONTAINERS_CONF="$CONF" podman --root "$STORE_ROOT" --runroot "$RUN_ROOT" "$@"
}

# The LBI store's libpod db records its static dir as the runroot path.
printf '[engine]\nstatic_dir="%s/libpod"\n' "$RUN_ROOT" > "$CONF"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/root" "$SCRATCH/run"

dup_ids=$(pod_ro images --format '{{.Id}}' | sort | uniq -d)
[ -z "$dup_ids" ] && exit 0

referenced=$(grep -rh '^Image=' \
    /usr/share/containers/systemd \
    /sysroot/ostree/deploy/*/deploy/*/usr/share/containers/systemd \
    --include '*.container' | cut -d= -f2- | sort -u || true)

# Restoring ro is best-effort: the mount is usually busy while containers hold
# overlay mounts on the store. bootc remounts as needed and a reboot restores
# ro, so a failure here is not worth aborting the upgrade over.
restore_ro=
restore_mount() {
    [ -n "$restore_ro" ] || return 0
    mount -o remount,ro /sysroot || true
}

for id in $dup_ids; do
    names=$(pod_ro images --format '{{.Repository}}:{{.Tag}}' --filter "id=$id")
    for name in $names; do
        if grep -qxF "$name" <<< "$referenced"; then
            echo "dedupe-bound-images: $id has referenced tag $name, skipping" >&2
            continue 2
        fi
    done
    if [ -z "$restore_ro" ] && findmnt -no OPTIONS /sysroot | grep -qw ro; then
        trap restore_mount EXIT
        mount -o remount,rw /sysroot
        restore_ro=1
    fi
    for name in $names; do
        echo "dedupe-bound-images: untagging $name from $id" >&2
        pod_rw untag "$id" "$name"
    done
done
