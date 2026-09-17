#!/bin/sh
# tools/mkinitrd.sh — the initramfs that makes a machine's disk.
#
# Built here, at RELEASE time, with docker; used on a machine that has none.
# That is the whole point: the thing a person downloads must not need the thing
# it replaces in order to be installed, and macOS cannot write ext4.
#
# What goes in: an alpine userspace, e2fsprogs for mke2fs, the guest's three
# programs and the kernel modules, and initrd/init-format as /init.
#
#   sh tools/mkinitrd.sh [out.gz]
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/.build/initrd-format.gz}"
IMAGE="${IMAGE:-alpine:latest}"
command -v docker >/dev/null 2>&1 || { echo "mkinitrd: needs docker (this is a release step)" >&2; exit 2; }

b="$here/.build"
pl="$b/payload-src"
rm -rf "$pl"; mkdir -p "$pl/opt"
# The guest's own, from wherever mvm build left them.
for n in mengd mrun mfwd; do
  src="$b/guest/$n"
  [ -x "$src" ] || { echo "mkinitrd: no $n -- run mvm build first" >&2; exit 1; }
  cp "$src" "$pl/opt/$n"
done
# The modules, when the kernel needs any. A kernel built here has them in it
# and there is nothing to carry -- which is the whole reason for building it.
if [ "$(awk '/^modules /{print $2}' "$b/kernel.lock" 2>/dev/null)" = built-in ]; then
  echo "mkinitrd: the kernel has them built in; no modules to carry"
else
  for m in "$b"/extra/*.ko; do
    [ -r "$m" ] || { echo "mkinitrd: no kernel modules -- run mvm build --kernel first" >&2; exit 1; }
    cp "$m" "$pl/opt/"
  done
fi
cp "$here/initrd/init-format" "$pl/init"
cp "$here/initrd/init-mengd-disk" "$pl/init-mengd-disk"
chmod 755 "$pl/init" "$pl/opt"/mengd "$pl/opt"/mrun "$pl/opt"/mfwd

# /payload rather than a bind mount the cpio would pick up empty: the directory
# a container mounts read-only cannot be copied over, and the first version of
# this shipped an initramfs whose payload was an empty mount point.
docker run --rm -v "$pl:/pl:ro" -v "$(cd "$(dirname "$out")" && pwd):/o" "$IMAGE" sh -c '
set -e
apk add --no-cache e2fsprogs cpio >/dev/null 2>&1
mkdir -p /payload && cp -a /pl/. /payload/
mv /payload/init /init && chmod 755 /init
cd /
find . -xdev -path ./proc -prune -o -path ./sys -prune -o -path ./pl -prune -o -path ./o -prune -o -print 2>/dev/null \
  | cpio -o -H newc 2>/dev/null | gzip -9 > /o/'"$(basename "$out")" \
  || { echo "mkinitrd: could not build the initramfs" >&2; exit 1; }

sz=$(wc -c < "$out" | tr -d ' ')
[ "$sz" -gt 2000000 ] || { echo "mkinitrd: the image is $sz bytes, which is too small to contain a userspace" >&2; exit 1; }
rm -rf "$pl"
echo "mkinitrd: $sz bytes -> $out"
