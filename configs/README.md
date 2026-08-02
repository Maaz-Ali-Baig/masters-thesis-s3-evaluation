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
| Garage | `~/garage.toml` | single file → `/etc/garage.toml` |
| RustFS | none — credentials passed as environment variables | n/a |

**Mount type matters.** Single-file bind mounts do not survive a Docker Desktop restart on Windows/WSL
and will break the container (see `setup_notes.md`, Issue 4). SeaweedFS has been migrated to a directory
mount for this reason; Garage still uses a single-file mount and is expected to hit the same failure.

See `setup_notes.md` at the repo root for the full `docker run` commands that reference these files.
