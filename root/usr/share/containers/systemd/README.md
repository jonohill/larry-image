# Quadlet units

Drop Podman Quadlet definitions here (`*.container`, `*.pod`, `*.network`,
`*.volume`). systemd generates services from them at boot.

Related units are grouped into per-service subdirectories (e.g. `webtop/`,
`yt-cast/`). Rootful Quadlet scans these subdirectories recursively, and unit
cross-references (`Pod=`, `Network=`) resolve by unit name regardless of which
directory the unit lives in. Shared resources used by several services (e.g.
`media.network`) stay at the top level.

On a bootc image the container store is read-only, so each unit needs:

    [Container]
    GlobalArgs=--storage-opt=additionalimagestore=/usr/lib/bootc/storage

## Consuming secrets

Secrets land in `/run/<service>/...` (see the repo's `secrets/` dir). To use
them, order the unit after the decryption service and reference the file:

    [Unit]
    After=download-secrets.service
    Requires=download-secrets.service

    [Container]
    Image=ghcr.io/example/app:1.2.3
    GlobalArgs=--storage-opt=additionalimagestore=/usr/lib/bootc/storage
    EnvironmentFile=/run/myservice/env

    [Install]
    WantedBy=multi-user.target

See `example.container.sample` for a complete example (rename to
`example.container` to activate).
