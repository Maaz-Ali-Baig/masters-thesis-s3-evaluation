#!/usr/bin/env bash
#
# Stops and removes the SeaweedFS container on THIS VM. The data under /srv/s3/disk1/seaweedfs and
# /srv/s3/disk2/seaweedfs and the config in /root/seaweedfs-config are kept.
#
#   bash seaweedfs-stop.sh

set -eu
hostname
podman rm -f seaweedfs
podman ps --all --format '{{.Names}} {{.Status}}' | grep -c . || true
