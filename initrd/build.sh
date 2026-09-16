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
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cid=$(docker create "$IMAGE" true) || { echo "docker create failed" >&2; exit 1; }
docker export "$cid" | tar x -C "$work"
docker rm -f "$cid" >/dev/null
cp "$here/init" "$work/init"; chmod 755 "$work/init"
docker run --rm -v "$work:/src:ro" -v "$(cd "$(dirname "$out")" && pwd):/out" "$IMAGE" sh -c \
  'apk add --no-cache cpio >/dev/null 2>&1; cd /src && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /out/'"$(basename "$out")"
ls -l "$out"
