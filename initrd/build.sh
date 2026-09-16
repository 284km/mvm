#!/bin/sh
# initrd/build.sh — make the initramfs the boot test uses.
#
# The root filesystem is an image's, exported with `docker export`, plus the
# init script next to this file. cpio and gzip run inside a container because
# macOS has neither in a form that writes a Linux newc archive.
#
#   sh initrd/build.sh <out.cpio.gz>
set -u
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../.build/initrd.gz}"
IMAGE="${IMAGE:-alpine:latest}"
# The work directory has to be somewhere the container runtime can bind-mount
# FROM. On macOS `mktemp -d` gives /var/folders/..., which colima does not
# mount, and a bind mount of an unmounted path is not an error -- the container
# just sees an empty directory. `find .` returned 1 entry and the archive came
# out 89 bytes, with nothing anywhere saying why.
work="$(cd "$(dirname "$out")" && pwd)/initrd-work"
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
cid=$(docker create "$IMAGE" true) || { echo "docker create failed" >&2; exit 1; }
docker export "$cid" | tar x -C "$work"
docker rm -f "$cid" >/dev/null
cp "$here/init" "$work/init"; chmod 755 "$work/init"
docker run --rm -v "$work:/src:ro" -v "$(cd "$(dirname "$out")" && pwd):/out" "$IMAGE" sh -c \
  'apk add --no-cache cpio >/dev/null 2>&1; cd /src && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /out/'"$(basename "$out")"
# An archive that small is an empty one, whatever the exit status said.
sz=$(wc -c < "$out" | tr -d ' ')
[ "$sz" -gt 100000 ] || { echo "initrd/build.sh: the archive is $sz bytes, which is empty" >&2; exit 1; }
ls -l "$out"
