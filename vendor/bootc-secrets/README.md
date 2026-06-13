# bootc-secrets

Reusable, host-autonomous secret management for bootc (and plain systemd)
hosts, using [age](https://github.com/FiloSottile/age) encryption.

Extracted from [naspi-image](https://github.com/jonohill/naspi-image) so the
same mechanism can be shared across multiple host images without copy/paste
drift.

## How it works

The whole secrets directory is packed into a single tar.gz and **age-encrypted
to one binary blob**, to two age recipients:

- **your personal age key** — so you can always decrypt, edit and re-encrypt
  locally;
- **the host's public key** — so the host can decrypt its own secrets at boot,
  with no operator interaction.

The host's age "key" is just its SSH host key: age can use an
`ssh-ed25519` key directly as an identity. So `host.pub` is the contents of
`/etc/ssh/ssh_host_ed25519_key.pub`, and the host decrypts with its matching
private key.

The blob is stored in an **S3/R2 bucket**, under a path derived from
the host's own key:

```
<bucket>/<host-key-fingerprint>/secrets
```

`<host-key-fingerprint>` is OpenSSH's SHA256 fingerprint of the host public
key, made base64url (path-safe) — see below. Because it's derived purely from
the key, the host computes the same path and fetches its own blob, with no
per-host configuration beyond a base URL.

At boot, `download-secrets.service` runs `download_secrets.sh`, which:

1. reads its config from `/etc/bootc-secrets/config.env`;
2. computes its fingerprint and downloads
   `$SECRETS_BASE_URL/<fingerprint>/secrets` over HTTP(S) with `curl`;
3. decrypts the blob with the host key and unpacks the tar.gz into `/run`
   (tmpfs, so plaintext never touches disk and is gone on reboot);
4. workloads then consume them, e.g. `EnvironmentFile=/run/myservice/env`.

### The host-key fingerprint

The path component is computed the same way on both sides:

```sh
ssh-keygen -l -f "$KEY" | awk '{print $2}' | sed 's/^SHA256://' | tr '+/' '-_' | tr -d '='
```

`ssh-keygen -l -f` works on **either** the public key (`host.pub`, used by
`crypt.sh --upload`) or the **private** key (`/etc/ssh/ssh_host_ed25519_key`,
used at boot) and yields the same value. It hashes the canonical key blob, so
it's independent of the comment/whitespace, and the `tr`/`tr -d` turn standard
base64 into base64url so the result is a stable, path-safe 43-char string.

## Layout

```
crypt.sh                       # local pack/encrypt/decrypt/rotate + upload tool
install/
  download_secrets.sh          # boot-time download + decrypt to /run
  download-secrets.service     # systemd oneshot unit
  install.sh                   # installs age + the above, enables the unit
secrets-template/              # copy into a consuming repo as secrets/
  .gitignore                   # keep only metadata local; nothing else committed
  README.md
```

## Using it in a host image

This repo is meant to be **vendored** into a host-image repo via
`git subtree` (see below), then wired into the build.

### 1. Per-host key material

In the consuming repo root, add `host.pub` — the host's SSH public key:

```sh
# On the host (or from a key you generated for it):
cat /etc/ssh/ssh_host_ed25519_key.pub > host.pub
```

Copy `secrets-template/` to `secrets/` in the consuming repo, then add one
directory per service, encrypt and upload:

```sh
mkdir -p secrets/myservice
printf 'TOKEN=...\n' > secrets/myservice/env

# AWS/R2 credentials (and endpoint, for R2) come from the environment.
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
export AWS_ENDPOINT_URL=https://<account>.r2.cloudflarestorage.com
export BUCKET=my-secrets-bucket

AGE_KEY="$(cat ~/age.key)" vendor/bootc-secrets/crypt.sh --encrypt --upload
```

This writes the blob to `s3://$BUCKET/<host-key-fingerprint>/secrets`. The
plaintext and the encrypted blob both stay out of git (see the template
`.gitignore`); only `host.pub` and metadata are worth committing.

You can also split the steps: `--encrypt` (writes `secrets.age` locally),
then `--upload` on its own to push an existing blob. `--decrypt` unpacks the
local blob back into `secrets/` for editing.

### 2. Install during the image build

In the `Containerfile` (prerequisites: `curl jq tar` — `curl` and `tar` are
also used at boot):

```dockerfile
RUN dnf install -y jq   # plus curl, tar (usually present)
COPY vendor/bootc-secrets/install /tmp/bootc-secrets-install
RUN /tmp/bootc-secrets-install/install.sh && rm -rf /tmp/bootc-secrets-install

# Tell the host where to fetch its secrets blob
RUN mkdir -p /etc/bootc-secrets && \
    printf 'SECRETS_BASE_URL=https://secrets.example.com\n' > /etc/bootc-secrets/config.env
```

`config.env` keys: `SECRETS_BASE_URL` (required — the bucket base URL; the
fingerprint and `/secrets` are appended), `HOST_KEY_PATH` (default
`/etc/ssh/ssh_host_ed25519_key`).

The boot download is an unauthenticated `curl` GET, so the bucket must be
**public-read**. That's safe because the blob is age-encrypted and the path is
an opaque key fingerprint — but the ciphertext is world-readable, so treat the
URL accordingly.

### 3. Order workloads after the secrets are present

In each Quadlet `.container` (or any unit) that needs a secret:

```ini
[Unit]
After=download-secrets.service
Requires=download-secrets.service
```

## Rotating

If the host key changes, update `host.pub`, then re-encrypt and re-upload to
the new key:

```sh
AGE_KEY="$(cat ~/age.key)" vendor/bootc-secrets/crypt.sh --rotate --upload
```

Note the upload path is keyed by the host fingerprint, so a new host key means
a **new object path**; the old blob (if any) can be deleted separately.

## Vendoring with git subtree

Add it once (lands as real, committed files — no submodule init needed):

```sh
git remote add bootc-secrets https://github.com/<you>/bootc-secrets.git
git subtree add --prefix=vendor/bootc-secrets bootc-secrets main --squash
```

Pull updates later:

```sh
git subtree pull --prefix=vendor/bootc-secrets bootc-secrets main --squash
```

Push fixes you made in-place back upstream:

```sh
git subtree push --prefix=vendor/bootc-secrets bootc-secrets main
```
