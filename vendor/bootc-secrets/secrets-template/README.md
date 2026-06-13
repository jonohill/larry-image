At runtime the secrets are unpacked into `/run`, so there should be one
directory here per service (e.g. `myservice/env` → `/run/myservice/env`).

Nothing here is committed except this metadata (see `.gitignore`): the
plaintext stays local, and the encrypted blob lives in the object store, not
git.

Use `crypt.sh --encrypt --upload` to pack, encrypt and upload, run from the
repo root. Use `--rotate` if the host key changes (then `--upload` again).
