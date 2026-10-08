#!/usr/bin/env bash
#
# Stops and removes the Garage container on THIS VM. The data under /srv/s3/disk1/garage and
# /srv/s3/disk2/garage and /etc/garage/garage.toml are NOT touched, so the node can be started
# again with garage-node.sh (which reuses the data). Wiping the data is a separate, deliberate
# step and is not part of this script.
#
#   bash garage-stop.sh

set -eu
[ "$(id -u)" = 0 ] || { echo "garage-stop: run as root" >&2; exit 1; }
hostname
podman rm -f garage 2>&1 || true
echo "containers left: $(podman ps --format '{{.Names}}' | wc -l)"
