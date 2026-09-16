#!/bin/sh
# test/disk.sh — P5.4: virtio-blk, judged from both ends.
#
# Not "the device registers read back". The guest has to MOUNT the disk and
# read a file the host put there, and then write one the host can find --
# neither of which can happen unless the queue was walked correctly, the data
# landed at the guest addresses the descriptors named, and the interrupt
# arrived.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
out="$here/.build"; mkdir -p "$out"
IMAGE_FILE="${IMAGE_FILE:-$out/Image}"
INITRD="${INITRD:-$out/initrd.gz}"
DISK="${DISK:-$out/disk.img}"
for f in "$IMAGE_FILE" "$INITRD" "$DISK"; do
  [ -r "$f" ] || { echo "missing $f" >&2; exit 2; }
done
MARK="${MARK:-this file came off a virtio-blk device emulated in Mere}"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build =="
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2>"$out/e1" || { echo FAIL mkdtb; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2>"$out/e2" || { echo FAIL boot;  sed -n 1,8p "$out/e2"; exit 1; }
cc -O2 -o "$out/mkdtb" "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done

sz=$(stat -f%z "$INITRD")
"$out/mkdtb" "$out/disk.dtb" $((0x4a000000)) $((0x4a000000 + sz)) >/dev/null 2>&1; say $? "device tree"

# A fresh copy, so a previous run's write cannot be mistaken for this one's.
cp "$DISK" "$out/disk-run.img"
"$out/mvm-boot" "$IMAGE_FILE" "$out/disk.dtb" "$INITRD" "$out/disk-run.img" \
  > "$out/disk-console.txt" 2> "$out/disk-vmm.txt"
c="$out/disk-console.txt"

echo "== the kernel found it =="
grep -q "virtio_blk virtio0" "$c"; say $? "the driver bound to the transport"
grep -q "\[vda\] 32768 512-byte logical blocks" "$c"
say $? "and read the capacity this VMM reported (32768 sectors = the image's size)"

echo "== the guest used it =="
grep -q "userspace: /dev/vda exists" "$c"; say $? "the block device exists in the guest"
grep -q "EXT4-fs (vda): mounted filesystem" "$c"; say $? "the guest mounted a real filesystem off it"
grep -q "userspace: disk says: $MARK" "$c"
say $? "and read back a file the host wrote into the image"

echo "== and wrote to it =="
grep -q "userspace: wrote a file back" "$c"; say $? "the guest wrote a file"
# The other end: the bytes have to be in the host's image, not just claimed.
if command -v docker >/dev/null; then
  found=$(docker run --rm --privileged -v "$out:/out" alpine:latest sh -c \
    'mkdir -p /m && mount -o loop /out/disk-run.img /m 2>/dev/null && cat /m/fromguest.txt 2>/dev/null; umount /m 2>/dev/null' 2>/dev/null | tr -d '\r\n')
  [ "$found" = "written by the guest" ]; say $? "and the host finds those bytes in the image ($found)"
else
  echo "  SKIP  no docker: the host side of the write is unchecked"; fail=1
fi

grep -q "Kernel panic" "$c" && { echo "  FAIL  the kernel panicked"; fail=1; } || echo "  ok    no panic"
[ "$fail" = 0 ] && echo "disk PASS" || echo "disk FAIL"
exit "$fail"
