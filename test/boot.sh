#!/bin/sh
# test/boot.sh — P5.2: a real Linux kernel boots far enough to panic.
#
# A panic is the judgement on purpose. It means the CPU, the memory map, the
# interrupt controller and the timer all worked -- and it is the first thing a
# guest says that a VMM which merely started cannot fake. The panic has to be
# the RIGHT one: no root filesystem, because virtio-blk is not written yet.
# Any other panic is a different failure wearing the same word.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
out="$here/.build"; mkdir -p "$out"
IMAGE="${IMAGE:-$out/Image}"
[ -r "$IMAGE" ] || { echo "no kernel at $IMAGE. Any arm64 Image will do:" >&2
                     echo "  gunzip -c /boot/vmlinuz-\$(uname -r) > $out/Image   (on an arm64 Linux)" >&2; exit 2; }
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build =="
for src in fdt mkdtb boot; do :; done
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2> "$out/e1" || { echo "FAIL: mkdtb emit"; sed -n 1,10p "$out/e1"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2> "$out/e2" || { echo "FAIL: boot emit";  sed -n 1,10p "$out/e2"; exit 1; }
cc -O2 -o "$out/mkdtb" "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>"$out/c1" || { echo FAIL cc mkdtb; sed -n 1,8p "$out/c1"; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c" "$here/hv_shim.c" -framework Hypervisor 2>"$out/c2" || { echo FAIL cc boot; sed -n 1,8p "$out/c2"; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done

echo "== the device tree =="
"$out/mkdtb" "$out/guest.dtb" 2>/dev/null; say $? "generated"
if command -v dtc >/dev/null; then
  dtc -I dtb -O dts "$out/guest.dtb" > "$out/guest.dts" 2> "$out/dtcerr"
  [ ! -s "$out/dtcerr" ]; say $? "dtc reads it back without complaint"
else
  echo "  SKIP  dtc not installed: the tree is unvalidated"; fail=1
fi

echo "== the guest =="
"$out/mvm-boot" "$IMAGE" "$out/guest.dtb" > "$out/console.txt" 2> "$out/vmm.txt"
n=$(grep -c '^\[' "$out/console.txt" || true)
[ "$n" -gt 100 ]; say $? "the kernel printed $n lines through the emulated PL011"
grep -q "Booting Linux on physical CPU" "$out/console.txt"; say $? "it started"
grep -q "Machine model: linux,dummy-virt"  "$out/console.txt"; say $? "it read the device tree this VMM wrote"
grep -qE "GICv3: [0-9]+ SPIs implemented"  "$out/console.txt"; say $? "the interrupt controller came up"
grep -q "arch_timer: cp15 timer"           "$out/console.txt"; say $? "the timer came up"
grep -q "devtmpfs: initialized"            "$out/console.txt"; say $? "it got as far as devtmpfs"

echo "== the right panic =="
grep -q "Kernel panic - not syncing: VFS: Unable to mount root fs" "$out/console.txt"
say $? "it panicked for the one thing this VMM does not provide: a root filesystem"
# Any OTHER panic is a different failure using the same word.
others=$(grep "Kernel panic" "$out/console.txt" | grep -vc "Unable to mount root fs" || true)
[ "$others" = 0 ]; say $? "and for nothing else ($others other panics)"
grep -q "PSCI SYSTEM_RESET" "$out/vmm.txt"; say $? "the guest asked to reset and this VMM answered"

echo "== poison: describe the GIC wrongly =="
sed 's|let _ = pc "reg" \[0, gic_dist, 0, dist_size, 0, gic_redist, 0, redist_size\] in|let _ = pc "reg" [0, gic_dist, 0, dist_size, 0, gic_redist, 0, redist_size * 8] in|' \
  "$here/mkdtb.mere" > "$out/poison.mere"
cmp -s "$here/mkdtb.mere" "$out/poison.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
"$M" -c "$out/poison.mere" > "$out/p.c" 2>/dev/null \
  && cc -O2 -o "$out/mkdtb-poison" "$out/p.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null \
  && codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mkdtb-poison" 2>/dev/null \
  && "$out/mkdtb-poison" "$out/poison.dtb" 2>/dev/null
"$out/mvm-boot" "$IMAGE" "$out/poison.dtb" > "$out/poison.txt" 2>&1
grep -q "Unable to mount root fs" "$out/poison.txt" \
  && { echo "  FAIL  a wrong GIC window still reached the panic"; fail=1; } \
  || echo "  ok    a GIC window larger than the framework answers for stops the boot"

[ "$fail" = 0 ] && echo "boot PASS" || echo "boot FAIL"
exit "$fail"
