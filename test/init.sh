#!/bin/sh
# test/init.sh — P5.3: userspace runs.
#
# A kernel that panics has a working CPU, memory, interrupt controller and
# timer. A kernel that reaches an init process and lets it mount filesystems
# and power the machine off has all of that AND a working userspace boundary.
# This is the step the project set out to reach.
#
# The guest's only channel before /dev exists is its EXIT STATUS, and the init
# script uses it: each step has a number, and the kernel prints
# "Attempted to kill init! exitcode=0xNN00". That is how the missing piece was
# found, so the test checks those numbers do NOT appear.
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
[ -r "$IMAGE_FILE" ] || { echo "no kernel at $IMAGE_FILE" >&2; exit 2; }
[ -r "$INITRD" ] || { echo "no initramfs at $INITRD -- sh initrd/build.sh" >&2; exit 2; }
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build =="
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2>"$out/e1" || { echo FAIL mkdtb; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2>"$out/e2" || { echo FAIL boot;  sed -n 1,8p "$out/e2"; exit 1; }
cc -O2 -o "$out/mkdtb" "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done

sz=$(stat -f%z "$INITRD")
start=$((0x4a000000)); end=$((start + sz))
"$out/mkdtb" "$out/initrd.dtb" "$start" "$end" >/dev/null 2>&1; say $? "device tree with the initrd's bounds in it"

echo "== the guest =="
"$out/mvm-boot" "$IMAGE_FILE" "$out/initrd.dtb" "$INITRD" > "$out/init-console.txt" 2> "$out/init-vmm.txt"
c="$out/init-console.txt"
grep -q "Trying to unpack rootfs image as initramfs" "$c"; say $? "the kernel found the initramfs"
grep -q "Run /init as init process" "$c"; say $? "and ran init"

echo "== userspace =="
grep -q "userspace: devtmpfs is mounted" "$c"; say $? "init mounted devtmpfs and can write to the kernel log"
grep -q "userspace: pid 1 uid 0"        "$c"; say $? "it is pid 1, running as root"
grep -q "userspace: uname Linux"        "$c"; say $? "it can run another program (uname)"
grep -q "userspace: init is done"       "$c"; say $? "it reached the end of its script"

echo "== a clean stop, not a crash =="
grep -q "reboot: Power down" "$c"; say $? "the guest powered itself down"
grep -q "PSCI SYSTEM_OFF" "$out/init-vmm.txt"; say $? "through PSCI, and this VMM answered"
# exitcode=0xNN00 is init dying. Each number in the init script marks a step,
# so any of them appearing says exactly which one failed.
grep -q "Attempted to kill init" "$c" && { echo "  FAIL  init died: $(grep -o 'exitcode=0x[0-9a-f]*' "$c")"; fail=1; } \
  || echo "  ok    init did not die"
grep -q "Kernel panic" "$c" && { echo "  FAIL  the kernel panicked"; fail=1; } || echo "  ok    no panic"

[ "$fail" = 0 ] && echo "init PASS" || echo "init FAIL"
exit "$fail"
