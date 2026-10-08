#!/usr/bin/env bash
#
# Stops and removes the RustFS container on THIS VM. The data under /srv/s3/disk1/rustfs and
# /srv/s3/disk2/rustfs and the config in /root/rustfs-config are kept.
#
#   bash rustfs-stop.sh

set -eu
hostname
podman rm -f rustfs
podman ps --all --format '{{.Names}} {{.Status}}' | grep -c . || true
