# Configuration Files

Reference copies of the config files used to run each system, kept here for reproducibility
(this maps to Appendix A — "Detailed System Configuration Files" — in the thesis).

Any secret-like value (signing keys, RPC secrets) is replaced with a placeholder and a comment
showing the exact command used to generate a real one. The actual running containers read their
live config from files in the WSL home directory (`~/seaweedfs-security.toml`, `~/garage.toml`,
etc.) — the copies here are for documentation and reproducibility, not live-mounted by Docker.
See `setup_notes.md` at the repo root for the full `docker run` commands that reference these files.
