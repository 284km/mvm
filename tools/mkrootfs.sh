#!/bin/sh
# tools/mkrootfs.sh — an ext4 root filesystem for the guest, built on the HOST.
#
#   sh tools/mkrootfs.sh <out.img> <size MiB> [extra dir]
#
# FOR THE CHECKS, NOT FOR INSTALLING. This needs docker twice -- once for the
# tree and once for mke2fs -- which is fine for a check running beside a docker
# that is already there, and impossible for a person installing a tool that
# replaces docker. `tools/mvm start` makes its disk the other way: the host
# makes a file of the right size and the GUEST formats it, from
# initrd/init-format. This one stays because several checks want a disk built
# from a particular image with a particular payload, before there is a machine.
#
# WHY A DISK AND NOT THE INITRAMFS. pivot_root refuses to work when the current
# root is the initramfs -- `mrun: pivot_root (errno 22)` -- so a container
# runtime cannot run there at all. A real filesystem on virtio-blk makes / an
# ordinary mount, which is what the runtime requires and what a real machine
# has.
#
# mke2fs -d builds the image FROM a directory, so nothing here needs to mount
# anything or be privileged.
set -u
out="${1:?usage: mkrootfs.sh <out.img> <size MiB> [extra dir]}"
mib="${2:-256}"
extra="${3:-}"
IMAGE="${IMAGE:-alpine:latest}"
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(cd "$(dirname "$out")" && pwd)/rootfs-work"
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
cid=$(docker create "$IMAGE" true) || { echo "docker create failed" >&2; exit 1; }
docker export "$cid" | tar x -C "$work"
docker rm -f "$cid" >/dev/null
[ -n "$extra" ] && { mkdir -p "$work/opt"; cp -R "$extra"/. "$work/opt/"; }
# /sbin/init in a container image is a symlink to busybox, and copying onto a
# symlink fails. Removing it first is the difference between replacing init and
# building an image that boots someone else's.
rm -f "$work/sbin/init"
cp "$here/initrd/init-mengd-disk" "$work/sbin/init"
chmod 755 "$work/sbin/init"
grep -q "init-mengd-disk" "$work/sbin/init" || {
  echo "mkrootfs.sh: /sbin/init in the tree is not the one this script was told to install" >&2
  exit 1; }
n=$(find "$work" | wc -l | tr -d ' ')
[ "$n" -gt 100 ] || { echo "mkrootfs.sh: the tree has $n entries, which is empty" >&2; exit 1; }
docker run --rm -v "$work:/src:ro" -v "$(cd "$(dirname "$out")" && pwd):/o" "$IMAGE" sh -c \
  "apk add --no-cache e2fsprogs >/dev/null 2>&1; dd if=/dev/zero of=/o/$(basename "$out") bs=1M count=$mib status=none && mke2fs -q -t ext4 -d /src -F /o/$(basename "$out")"
sz=$(wc -c < "$out" | tr -d ' ')
[ "$sz" -gt 1000000 ] || { echo "mkrootfs.sh: the image is $sz bytes" >&2; exit 1; }
ls -l "$out"
