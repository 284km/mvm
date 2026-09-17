#!/bin/sh
# kernel/build.sh — build the guest's kernel, inside a container.
#
# A FILE, not a string inside tools/mkkernel.sh. The first version of this was
# embedded in a double-quoted `docker run sh -c "..."`, where every $ belongs to
# whichever shell escapes it last; one of them did not, the host expanded it,
# and `set -u` stopped the build with "t: unbound variable" before it began.
#
#   sh build.sh <kversion> <sha256 or -> <fragment> <outdir>
set -eu
kver="$1"; ksha="$2"; frag="$3"; out="$4"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null 2>&1
apt-get -qq install -y --no-install-recommends \
  build-essential bc bison flex libssl-dev libelf-dev xz-utils curl ca-certificates >/dev/null 2>&1

# THE TARBALL LIVES ON THE MOUNT, THE TREE DOES NOT.
#
# $out is a directory on the host, bind-mounted in. Unpacking a kernel source
# tree onto a macOS-backed mount fails outright -- tar cannot create half of
# it, "Permission denied" on file after file -- for the same reason a Linux
# root filesystem cannot be unpacked there: the ownership and modes are not the
# host filesystem's to keep. One file is fine, and keeping it there means the
# 142 MB is downloaded once.
cd "$out"
t="linux-$kver.tar.xz"
[ -f "$t" ] || curl -sLo "$t" "https://cdn.kernel.org/pub/linux/kernel/v6.x/$t"
# THE PIN IS A DIGEST. A version is a name, and a name can be republished.
if [ "$ksha" != "-" ]; then
  echo "$ksha  $t" | sha256sum -c - >/dev/null || {
    echo "build.sh: $t is not the tarball this pins to" >&2; exit 3; }
fi
mkdir -p /build
cd /build
rm -rf "linux-$kver"
tar xf "$out/$t"
cd "linux-$kver"

make ARCH=arm64 defconfig >/dev/null 2>&1
# scripts/config, not appending to .config: appending leaves the old line in
# place and olddefconfig takes whichever it reaches first.
for k in $(grep '^CONFIG_' "$frag" | sed 's/^CONFIG_//; s/=y$//'); do
  ./scripts/config --enable "$k"
done
# Debug information is most of the build and none of the machine.
./scripts/config --disable DEBUG_INFO_BTF --disable DEBUG_INFO_DWARF5 >/dev/null 2>&1 || true
make ARCH=arm64 olddefconfig >/dev/null 2>&1

# VERIFIED AFTER olddefconfig, not before. A symbol whose dependencies are not
# met is dropped silently, and the Image would then be missing exactly one
# capability with nothing to say which.
miss=""
for k in $(grep '^CONFIG_' "$frag" | sed 's/^CONFIG_//; s/=y$//'); do
  [ "$(./scripts/config --state "$k")" = y ] || miss="$miss $k"
done
[ -z "$miss" ] || { echo "build.sh: these did not take:$miss" >&2; exit 3; }

make ARCH=arm64 -j"$(nproc)" Image > "$out/build.log" 2>&1 || {
  tail -20 "$out/build.log" >&2; exit 3; }
cp arch/arm64/boot/Image "$out/Image"
cp .config "$out/config"
cd "$out" && sha256sum Image > Image.sha256
