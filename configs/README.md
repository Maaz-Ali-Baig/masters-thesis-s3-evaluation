# Configuration Files

Reference copies of the config files used to run each system, kept here for reproducibility
(this maps to Appendix A — "Detailed System Configuration Files" — in the thesis).

Any secret-like value (signing keys, RPC secrets) is replaced with a placeholder and a comment
showing the exact command used to generate a real one. The copies here are for documentation and
reproducibility — they are not the files Docker mounts at runtime.

Live config locations in WSL (what the running containers actually read):

| System | Live location | Mounted as |
|---|---|---|
| SeaweedFS | `~/seaweedfs-config/security.toml`, `~/seaweedfs-config/s3_config.json` | directory → `/etc/seaweedfs` |
| Garage | `~/garage-config/garage.toml` | directory → `/etc/garage` |
| RustFS | none — credentials passed as environment variables | n/a |

**Mount type matters.** Single-file bind mounts do not survive a Docker Desktop restart on Windows/WSL
and will break the container (see `setup_notes.md`, Issue 4). Both SeaweedFS and Garage have been
migrated to directory mounts for this reason; RustFS needs no config file, so the problem does not arise.

Note that moving Garage's config also changed how it is invoked: the server needs
`-c /etc/garage/garage.toml`, and so does every `docker exec garage /garage …` CLI call, because the CLI
reads the config to locate the running node. See `setup_notes.md`, Issue 7.

**Credentials are not stored here.** The real access keys used to address each system live in
`~/.thesis-s3-env` (outside the repository, mode 600) and are read by `scripts/s3-helpers.sh`. Each system
needs a different key *and* a different region — Garage rejects the usual `us-east-1` default. See
`scripts/README.md`.

See `setup_notes.md` at the repo root for the full `docker run` commands that reference these files.
