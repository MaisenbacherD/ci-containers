#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Author: Dennis Maisenbacher <dennis.maisenbacher@wdc.com>
#
# Build the customized nvmetcli containerDisk qcow2 for a distro: extract the
# base cloud image out of its KubeVirt containerDisk and inject the nvmetcli
# tools with virt-customize. Produces nvmetcli/build/<distro>-nvmetcli.qcow2,
# which nvmetcli/Dockerfile.<distro>.containerdisk then packages as a scratch
# containerDisk.
#
# virt-customize runs here on the host, not inside the container build: its
# libguestfs appliance has no working DNS inside a BuildKit sandbox on hosted
# CI runners. Requires guestfs-tools. The container runtime can be overridden,
# e.g. DOCKER="sudo docker".
#
# On Debian/Ubuntu, libguestfs prefers passt for the appliance network, but
# passt refuses to run as root (it drops to "nobody" and then cannot write its
# PID file into root's tmpdir -> "passt exited with status 1"). Removing passt
# makes libguestfs fall back to qemu's SLIRP, which works:
#   sudo apt-get remove -y passt

set -euo pipefail

distro="${1:?usage: build-containerdisk.sh <distro>}"
DOCKER="${DOCKER:-docker}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_image="$(./generate.py --distro "$distro" --bundles nvmetcli \
    --base-images containerdisk_base_images --print-base-image)"
packages="$(./generate.py --distro "$distro" --bundles nvmetcli --print-packages)"

builddir="nvmetcli/build"
workdir="${builddir}/.extract-${distro}"
qcow="${builddir}/${distro}-nvmetcli.qcow2"

rm -rf "$workdir"
mkdir -p "$workdir"

# Extract the bootable qcow2 from the base containerDisk. It is a scratch image
# holding the disk in /disk, so give `docker create` a dummy command (the
# container is never started).
echo "Extracting base disk from ${base_image} ..."
cid="$($DOCKER create "$base_image" nvmetcli-extract)"
$DOCKER cp "${cid}:/disk/." "$workdir/"
$DOCKER rm "$cid" >/dev/null

src="$(find "$workdir" -maxdepth 1 -type f | head -n1)"
if [ -z "$src" ]; then
    echo "error: no disk image found in ${base_image}:/disk" >&2
    exit 1
fi

relabel=()
if [ "$distro" = "fedora" ]; then
    relabel=(--selinux-relabel)
fi

# Run virt-customize as root: on Debian/Ubuntu the host kernel is mode 0600, so
# an unprivileged libguestfs cannot read /boot/vmlinuz to build its appliance;
# root also gets /dev/kvm. LIBGUESTFS_BACKEND=direct avoids needing libvirtd.
echo "Injecting nvmetcli tools with virt-customize: ${packages}"
sudo env LIBGUESTFS_BACKEND=direct virt-customize -a "$src" "${relabel[@]}" \
    --install "$packages"

sudo mv -f "$src" "$qcow"
sudo chown "$(id -u):$(id -g)" "$qcow"
sudo rm -rf "$workdir"
echo "Created ${qcow}"
