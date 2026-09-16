#!/bin/sh
# test/vsock.sh — P5.5: the guest and the host hold a conversation.
#
# WHAT IS BEING JUDGED. Not "the device answered its registers" -- a device
# that answers registers and moves nothing looks identical from outside. The
# judgement is that bytes the GUEST wrote arrived at a program on the HOST, and
# that bytes that program wrote came back. Both halves, or neither counts.
#
# The host's reply is DERIVED from what arrived rather than echoed, because an
# echo cannot tell "the bytes made the round trip" apart from "the guest is
# looking at its own transmit buffer", and those are the two things this has to
# distinguish.
#
# WHAT IT NEEDS, and why none of it can be faked here:
#   - an arm64 Image: gunzip -c /boot/vmlinuz-$(uname -r) > .build/Image
#   - VSMOD=<dir> with vsock.ko, vmw_vsock_virtio_transport_common.ko and
#     vmw_vsock_virtio_transport.ko from THAT kernel. vsock is =m in a stock
#     kernel, so it is not in the image; the modules come from
#     /lib/modules/$(uname -r)/kernel/net/vmw_vsock (zstd-compressed there).
#   - a container runtime, to build the guest client: the guest has no
#     compiler and busybox's nc does not speak AF_VSOCK.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
out="$here/.build"; mkdir -p "$out"
IMAGE_FILE="${IMAGE_FILE:-$out/Image}"
[ -r "$IMAGE_FILE" ] || { echo "no kernel at $IMAGE_FILE" >&2; exit 2; }
VSMOD="${VSMOD:-$out/extra}"
for m in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport; do
  [ -r "$VSMOD/$m.ko" ] || { echo "no $m.ko in $VSMOD -- set VSMOD (see the header)" >&2; exit 2; }
done
command -v docker >/dev/null 2>&1 || { echo "needs a container runtime to build the guest client" >&2; exit 2; }
# The console comes out of the emulated PL011, which ends lines with CRLF, so
# an end-of-line anchor has to allow for the CR. Anchoring matters here: the
# markers are prefixes of each other's failure forms.
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== the guest's client =="
docker run --rm -v "$here/guest:/w" -w /w gcc:14 \
  sh -c 'cc -O2 -static -o vsock_client vsock_client.c' >/dev/null 2>&1
[ -x "$here/guest/vsock_client" ]; say $? "an arm64 client that speaks AF_VSOCK"

echo "== build =="
mkdir -p "$out/extra"
[ "$(cd "$VSMOD" && pwd)" = "$out/extra" ] || cp "$VSMOD"/vsock.ko "$VSMOD"/vmw_vsock_virtio_transport_common.ko \
   "$VSMOD"/vmw_vsock_virtio_transport.ko "$out/extra/"
cp "$here/guest/vsock_client" "$out/extra/"
INIT="$here/initrd/init-vsock" EXTRA="$out/extra" \
  sh "$here/initrd/build.sh" "$out/initrd-vsock.gz" >/dev/null 2>&1
[ -r "$out/initrd-vsock.gz" ]; say $? "an initramfs with the modules and the client in it"
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2>"$out/e1" || { echo FAIL mkdtb; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2>"$out/e2" || { echo FAIL boot;  sed -n 1,8p "$out/e2"; exit 1; }
cc -O2 -o "$out/mkdtb" "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done
sz=$(stat -f%z "$out/initrd-vsock.gz"); start=$((0x4a000000))
"$out/mkdtb" "$out/vsock.dtb" "$start" $((start + sz)) >/dev/null 2>&1; say $? "a device tree with both transports in it"

run() {  # run() <socket path or empty> <console file> <vmm file>
  s="$1"; c="$2"; v="$3"
  MVM_VSOCK="$s" MVM_TIMEOUT_MS="${MVM_TIMEOUT_MS:-15000}" \
    "$out/mvm-boot" "$IMAGE_FILE" "$out/vsock.dtb" "$out/initrd-vsock.gz" > "$c" 2> "$v"
}

echo "== the conversation =="
SOCK="$out/vs.sock"; rm -f "$SOCK"
python3 "$here/test/vsock_host.py" "$SOCK" 65536 > "$out/host.log" 2>&1 &
hpid=$!
wait_sock() { i=0; while [ ! -S "$1" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done; }
wait_sock "$SOCK"
[ -S "$SOCK" ]; say $? "a host program is listening on a unix socket"
run "$SOCK" "$out/vsock-console.txt" "$out/vsock-vmm.txt"
wait "$hpid" 2>/dev/null
c="$out/vsock-console.txt"; v="$out/vsock-vmm.txt"

grep -qaE "\] userspace: insmod vmw_vsock_virtio_transport ok[[:space:]]*$" "$c"; say $? "the guest loaded the vsock modules"
grep -qa "] userspace: virtio device virtio1 id 0x0013 " "$c"; say $? "and found a vsock device on the virtio bus"
grep -qa "^mvm: vsock stream open" "$v"; say $? "the guest asked to connect and this VMM opened the host end"
# 20 bytes is the client's message. The host counts what it actually read, so
# this number is the guest's bytes arriving, not a claim that they were sent.
grep -qa "] userspace: vsock_client exit 0:" "$c"; say $? "the client returned success"
grep -qa "host saw 20 bytes" "$c"; say $? "the host received the guest's 20 bytes"
grep -qa "HELLO FROM THE GUEST" "$c"; say $? "and the guest read back what the host made of them"
grep -qa "] userspace: vsock_bulk exit 0:" "$c"; say $? "a second, bigger stream ran on the same device"
grep -qa "bulk ok 65536 bytes each way" "$c"; say $? "65536 bytes each way, every byte checked by value"
grep -qa "^bulk received 65536 of 65536$" "$out/host.log"; say $? "and the host counted all of them arriving"
grep -qa "^bulk content ok$" "$out/host.log"; say $? "in the right order"
grep -qaE "\] userspace: init-vsock done[[:space:]]*$" "$c"; say $? "init reached the end of its script"
grep -qa "guest called PSCI SYSTEM_OFF" "$v"; say $? "the guest powered itself down"
grep -qa "gave up at the deadline" "$v" && { echo "  FAIL  the run ended at the deadline"; fail=1; } \
  || echo "  ok    and did so before the deadline"
grep -qa "Kernel panic" "$c" && { echo "  FAIL  the kernel panicked"; fail=1; } || echo "  ok    no panic"

echo "== poison: take the host program away =="
# A stream to nothing must be REFUSED, and refused by a packet the guest can
# see. The failure this catches is a device that accepts the connection and
# leaves the guest waiting: the client would hang, the deadline would fire, and
# a check that only looked for "no reply" would call that a pass.
rm -f "$SOCK"
run "$SOCK" "$out/poison-console.txt" "$out/poison-vmm.txt"
pc="$out/poison-console.txt"
grep -qa "nothing listening at" "$out/poison-vmm.txt"; say $? "the VMM said what it could not reach"
grep -qa "] userspace: vsock_client exit 11:" "$pc"; say $? "and the guest's connect() failed instead of hanging"
grep -qaE "\] userspace: init-vsock done[[:space:]]*$" "$pc"; say $? "so init still finished"
grep -qa "host saw" "$pc" && { echo "  FAIL  a reply arrived with no host to send it"; fail=1; } \
  || echo "  ok    and no reply arrived"

echo "== poison: stop waking the vCPU for the host =="
# The bug this reproduces was real and cost the first three runs: the loop
# polled the host end only on exits it stopped receiving once the virtual timer
# was masked -- 4 polls in 52,189 exits. Everything up to the guest's write
# still worked, so a check that stopped at "the stream opened" was green.
sed 's|let _ = hv_vs_wake_on h in|let _ = 0 in|' "$here/vsock.mere" > "$out/poison-vsock.mere"
cmp -s "$here/vsock.mere" "$out/poison-vsock.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cp "$here/virtio.mere" "$out/virtio.mere"
cp "$here/boot.mere" "$out/poison-boot.mere"
sed -i '' 's|import "vsock.mere";|import "poison-vsock.mere";|' "$out/poison-boot.mere"
if "$M" -c "$out/poison-boot.mere" > "$out/pb.c" 2>/dev/null \
   && cc -O2 -o "$out/mvm-poison" "$out/pb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null; then
  codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-poison" 2>/dev/null
  rm -f "$SOCK"
  python3 "$here/test/vsock_host.py" "$SOCK" 65536 > "$out/host2.log" 2>&1 &
  hpid=$!
  wait_sock "$SOCK"
  MVM_VSOCK="$SOCK" MVM_TIMEOUT_MS=8000 \
    "$out/mvm-poison" "$IMAGE_FILE" "$out/vsock.dtb" "$out/initrd-vsock.gz" \
    > "$out/poison2-console.txt" 2> "$out/poison2-vmm.txt"
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  # The stream still opens and the guest still writes -- that is the point.
  grep -qa "^mvm: vsock stream open" "$out/poison2-vmm.txt"; say $? "the stream still opens without the wake-up"
  grep -qa "HELLO FROM THE GUEST" "$out/poison2-console.txt" \
    && { echo "  FAIL  the reply arrived anyway, so this gate does not depend on the wake-up"; fail=1; } \
    || echo "  ok    but the reply never reaches the guest, and this gate sees it"
else
  echo "  FAIL  the poisoned VMM did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "vsock PASS" || echo "vsock FAIL"
exit "$fail"
