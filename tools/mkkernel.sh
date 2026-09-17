#!/bin/sh
# tools/mkkernel.sh — the guest's kernel, from a pinned package.
#
# WHY THIS EXISTS. Until now the answer to "where does .build/Image come from"
# was "gunzip /boot/vmlinuz on a Linux box that runs that kernel" -- which
# means somebody with only a Mac cannot start. The kernel is the one piece of
# this stack that is not built here and not shipped here, and a tool that
# cannot obtain it is a tool nobody else can run.
#
# WHAT IT PRODUCES, and why exactly this and not something smaller:
#
#   .build/Image        the raw arm64 kernel   (59,009,416 bytes for 6.8.0-117)
#   .build/extra/*.ko   eight modules          (each one is a feature)
#   .build/kernel.lock  what it took, by digest
#
# THE PIN IS EXACT. The Image this produces for 6.8.0-117-generic has sha256
# ce3cccafc326c6e1cf88a35e2976df1c084f5b1349abc70d0c94f7573181450e, which is
# byte for byte the kernel every check in this repository has been green
# against. Obtaining it this way is not a new kernel to re-validate.
#
# WHY UBUNTU'S GENERIC KERNEL AND NOT A SMALLER ONE. Alpine's linux-virt is
# 9.2 MB against 18.3 and has all eight modules, and it was measured and set
# aside for one reason:
#
#   CONFIG_VIRTIO_MMIO=m  CONFIG_VIRTIO_BLK=m  CONFIG_EXT4_FS=m
#
# A kernel whose virtio and ext4 are modules cannot mount root=/dev/vda without
# an initramfs to load them first. Ubuntu's are all =y, which is exactly why
# this VMM boots with no initrd at all. (Alpine's vmlinuz is also an EFI zboot
# container -- "MZ\0\0zimg", gzip payload at a stated offset -- so it is not a
# gunzip either. Both facts belong to whoever tries option 3: building it.)
#
#   sh tools/mkkernel.sh [--version V] [--from-dir DIR] [--image IMG]
#   sh tools/mkkernel.sh --from-source [--kversion 6.8]
#
# --from-source builds one instead, from kernel.org, with kernel/config.fragment
# on top of arm64 defconfig. That fragment is NINE lines, and what it buys is
# that there are no modules at all: no eight files to ship beside the Image, no
# version that has to match it, no insmod at boot. Measured: 287 seconds on six
# cores, and an Image of 44.5 MB against the package's 59.
#
# --from-dir takes .deb files that are already on this machine, for the day the
# archive stops carrying this version. That day is coming: the package lives in
# noble-updates, which holds the current one.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"
VER="6.8.0-117-generic"
FROM=""
IMG="ubuntu:24.04"
SOURCE=0
KVER="6.8"
# The tarball this pins to. A digest rather than a version, because a version
# is a name and a name can be republished.
KSHA="c969dea4e8bb6be991bbf7c010ba0e0a5643a3a8d8fb0a2aaa053406f1e965f3"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VER="$2"; shift 2;;
    --from-dir) FROM="$(cd "$2" && pwd)"; shift 2;;
    --image) IMG="$2"; shift 2;;
    --from-source) SOURCE=1; shift;;
    --kversion) KVER="$2"; KSHA=""; shift 2;;
    *) echo "mkkernel: unknown option $1" >&2; exit 2;;
  esac
done
command -v docker >/dev/null 2>&1 || { echo "mkkernel: needs docker to open the packages" >&2; exit 2; }
mkdir -p "$out/extra" "$out/kernel-work"
W="$out/kernel-work"

# The eight. Each one is named because each one is a capability, and a kernel
# missing one is a machine that does a little less without saying so.
MODS="vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport overlay veth bridge stp llc"

if [ "$SOURCE" = 1 ]; then
  echo "mkkernel: building linux-$KVER from source (about five minutes on six cores)"
  [ -r "$here/kernel/config.fragment" ] || { echo "mkkernel: no kernel/config.fragment" >&2; exit 1; }
  mkdir -p "$W"
  # THE FRAGMENT GOES IN AS A FILE, not as a list inside this script: it is the
  # whole description of what this machine needs, and it has to be readable
  # without reading a shell script.
  cp "$here/kernel/config.fragment" "$W/fragment"
  cp "$here/kernel/build.sh" "$W/build.sh"
  docker run --rm -v "$W:/o" "$IMG" sh /o/build.sh "$KVER" "${KSHA:--}" /o/fragment /o \
    || { echo "mkkernel: the kernel did not build" >&2; exit 1; }
  [ -r "$W/Image" ] || { echo "mkkernel: no Image came out" >&2; exit 1; }
  [ "$(od -An -c -j56 -N4 "$W/Image" | tr -d ' \n')" = "ARMd" ] \
    || { echo "mkkernel: that is not an arm64 Image" >&2; exit 1; }
  mv "$W/Image" "$out/Image"
  cp "$W/config" "$out/kernel.config"
  # NO MODULES. That is the whole point of building it, so the old ones are
  # taken away rather than left to be loaded into a kernel they do not match.
  rm -f "$out"/extra/*.ko
  {
    echo "# what .build/Image was made from"
    echo "version linux-$KVER (built here)"
    echo "source  kernel.org, with kernel/config.fragment on arm64 defconfig"
    echo "modules built-in"
    [ -n "$KSHA" ] && echo "$KSHA  linux-$KVER.tar.xz"
    cat "$W/Image.sha256" 2>/dev/null
  } > "$out/kernel.lock"
  rm -rf "$W"
  echo "mkkernel: $(wc -c < "$out/Image" | tr -d ' ') bytes of kernel, and no modules to ship"
  sed -n '2,9p' "$out/kernel.lock" | sed 's/^/  /'
  exit 0
fi

if [ -n "$FROM" ]; then
  echo "mkkernel: using the .deb files in $FROM"
  MOUNT="-v $FROM:/debs:ro"
  GET="cp /debs/linux-image-${VER}_*.deb /debs/linux-modules-${VER}_*.deb /tmp/ 2>/dev/null || cp /debs/*.deb /tmp/"
else
  echo "mkkernel: fetching linux-image-$VER and linux-modules-$VER"
  MOUNT=""
  # Downloaded into /tmp, which is where the container is already standing --
  # a `mv ./*.deb /tmp/` after it moves a file onto itself and fails.
  GET="apt-get download -qq linux-image-$VER linux-modules-$VER >/dev/null 2>&1"
fi

# Everything happens in the container, including the digests: the answer has to
# be about the bytes that were opened, not about a copy of them.
# zstd and xz because that is how the modules are stored: Ubuntu ships them as
# .ko.zst, and `find` saying the file is there is not the same as being able to
# open it -- the first version of this script reported all eight present and
# then could not decompress one. The guest insmods a plain .ko.
docker run --rm $MOUNT -v "$W:/o" "$IMG" sh -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends zstd xz-utils >/dev/null 2>&1
cd /tmp
$GET
ls linux-image-${VER}_*.deb >/dev/null 2>&1 || { echo 'MISSING the linux-image package' >&2; exit 3; }
ls linux-modules-${VER}_*.deb >/dev/null 2>&1 || { echo 'MISSING the linux-modules package -- the kernel alone carries no modules' >&2; exit 3; }
sha256sum linux-image-${VER}_*.deb linux-modules-${VER}_*.deb > /o/packages.sha256
mkdir -p x && dpkg-deb -x linux-image-${VER}_*.deb x && dpkg-deb -x linux-modules-${VER}_*.deb x
V=\$(ls x/boot/vmlinuz-* 2>/dev/null | head -1)
[ -n \"\$V\" ] || { echo 'no vmlinuz in the package' >&2; exit 3; }
# gzip, or an EFI zboot container with a gzip payload inside it. Both exist on
# arm64 and they are not the same file; guessing produces a kernel that does
# not boot rather than an error.
if gzip -t \"\$V\" 2>/dev/null; then
  gzip -dc \"\$V\" > /o/Image
elif [ \"\$(head -c 8 \"\$V\" | od -An -c | tr -d ' \\n')\" = 'MZ\\\\0\\\\0zimg' ]; then
  echo 'this vmlinuz is an EFI zboot container -- not handled; see the header of this script' >&2; exit 3
else
  cp \"\$V\" /o/Image
fi
# The arm64 boot header says what it is, at 0x38. A file that is not one would
# be carried all the way to a machine that hangs with nothing on the console.
[ \"\$(od -An -c -j56 -N4 /o/Image | tr -d ' \\n')\" = 'ARMd' ] || { echo 'that is not an arm64 Image' >&2; exit 3; }
mkdir -p /o/extra
for m in $MODS; do
  p=\$(find x -name \"\$m.ko\" -o -name \"\$m.ko.gz\" -o -name \"\$m.ko.xz\" -o -name \"\$m.ko.zst\" 2>/dev/null | head -1)
  [ -n \"\$p\" ] || { echo \"MISSING module \$m\" >&2; exit 3; }
  case \"\$p\" in
    *.gz)  gzip -dc \"\$p\"  > /o/extra/\$m.ko;;
    *.xz)  xz -dc \"\$p\"    > /o/extra/\$m.ko 2>/dev/null || { echo \"cannot decompress \$p\" >&2; exit 3; };;
    *.zst) zstd -dc \"\$p\"  > /o/extra/\$m.ko 2>/dev/null || { echo \"cannot decompress \$p\" >&2; exit 3; };;
    *)     cp \"\$p\" /o/extra/\$m.ko;;
  esac
done
sha256sum /o/Image | sed 's|/o/||' > /o/Image.sha256
" || { echo "mkkernel: could not get the kernel out of the packages" >&2; exit 1; }

[ -r "$W/Image" ] || { echo "mkkernel: no Image came out" >&2; exit 1; }
mv "$W/Image" "$out/Image"
for m in $MODS; do
  [ -r "$W/extra/$m.ko" ] || { echo "mkkernel: $m.ko did not come out" >&2; exit 1; }
  mv "$W/extra/$m.ko" "$out/extra/$m.ko"
done
{
  echo "# what .build/Image and .build/extra/*.ko were made from"
  echo "version $VER"
  echo "source  ${FROM:-ubuntu archive ($IMG)}"
  echo "modules from-package"
  cat "$W/packages.sha256" 2>/dev/null
  cat "$W/Image.sha256" 2>/dev/null
} > "$out/kernel.lock"
rm -rf "$W"
echo "mkkernel: $(wc -c < "$out/Image" | tr -d ' ') bytes of kernel and $(ls "$out/extra"/*.ko | wc -l | tr -d ' ') modules"
sed -n '2,9p' "$out/kernel.lock" | sed 's/^/  /'
