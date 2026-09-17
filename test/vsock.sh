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
docker run --rm -v "$here/guest:/w" -w /w gcc:14 sh -c \
  'cc -O2 -static -o vsock_client vsock_client.c && cc -O2 -static -o vsock_server vsock_server.c' \
  >/dev/null 2>&1
[ -x "$here/guest/vsock_client" ] && [ -x "$here/guest/vsock_server" ]
say $? "an arm64 client and server that speak AF_VSOCK"

echo "== build =="
mkdir -p "$out/extra"
[ "$(cd "$VSMOD" && pwd)" = "$out/extra" ] || cp "$VSMOD"/vsock.ko "$VSMOD"/vmw_vsock_virtio_transport_common.ko \
   "$VSMOD"/vmw_vsock_virtio_transport.ko "$out/extra/"
cp "$here/guest/vsock_client" "$here/guest/vsock_server" "$out/extra/"
INIT="$here/initrd/init-vsock" EXTRA="$out/extra" \
  sh "$here/initrd/build.sh" "$out/initrd-vsock.gz" >/dev/null 2>&1
[ -r "$out/initrd-vsock.gz" ]; say $? "an initramfs with the modules and the client in it"
INIT="$here/initrd/init-vsock-in" EXTRA="$out/extra" \
  sh "$here/initrd/build.sh" "$out/initrd-vsock-in.gz" >/dev/null 2>&1
[ -r "$out/initrd-vsock-in.gz" ]; say $? "and one that runs a server inside the guest"
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2>"$out/e1" || { echo FAIL mkdtb; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2>"$out/e2" || { echo FAIL boot;  sed -n 1,8p "$out/e2"; exit 1; }
cc -O2 -o "$out/mkdtb" "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done
# A device tree per initramfs. The tree carries the initrd's BOUNDS, so one
# built for a different archive hands the kernel a SHORTER length -- and a
# truncated initramfs is not an error, it is an archive with files missing.
# That cost an hour: every command in the guest failed instantly with no
# message, because the programs were not there.
dtb_for() {  # dtb_for <initrd> <out dtb>
  sz=$(stat -f%z "$1"); start=$((0x4a000000))
  "$out/mkdtb" "$2" "$start" $((start + sz)) >/dev/null 2>&1
}
dtb_for "$out/initrd-vsock.gz" "$out/vsock.dtb"; r=$?
dtb_for "$out/initrd-vsock-in.gz" "$out/vsock-in.dtb"; r=$((r + $?))
[ "$r" = 0 ]; say $? "a device tree for each, with both transports in it"

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
# The VM has stopped, so anything the listener is still waiting for is never
# coming. Waiting for it here is how this gate hung instead of going red.
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
c="$out/vsock-console.txt"; v="$out/vsock-vmm.txt"

grep -qaE "\] userspace: insmod vmw_vsock_virtio_transport ok[[:space:]]*$" "$c"; say $? "the guest loaded the vsock modules"
grep -qa "] userspace: virtio device virtio1 id 0x0013 " "$c"; say $? "and found a vsock device on the virtio bus"
grep -qa "^mvm: vsock outward stream, guest port" "$v"; say $? "the guest asked to connect and this VMM opened the host end"
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

echo "== the other direction: the host connects in =="
# The VMM listens on a path on the HOST filesystem and starts the handshake
# toward a port the guest is listening on. A host program connects to an
# ordinary unix socket and does not know a VM is involved.
IN="$out/vs-in.sock"; rm -f "$IN"
( MVM_VSOCK_IN="$IN" MVM_VSOCK_PORT=1024 MVM_TIMEOUT_MS=30000 \
    "$out/mvm-boot" "$IMAGE_FILE" "$out/vsock-in.dtb" "$out/initrd-vsock-in.gz" \
    > "$out/in-console.txt" 2> "$out/in-vmm.txt" ) &
vmpid=$!
python3 "$here/test/vsock_in.py" "$IN" "hello from the host" 25 > "$out/in1.log" 2>&1
r1=$?
python3 "$here/test/vsock_in.py" "$IN" "and again" 25 > "$out/in2.log" 2>&1
r2=$?
wait "$vmpid" 2>/dev/null
ic="$out/in-console.txt"
grep -qa "] userspace: vsock-server: listening on port 1024" "$ic" \
  || grep -qa "vsock-server: listening on port 1024" "$ic"
say $? "a server is listening inside the guest"
grep -qa "^mvm: vsock listening at" "$out/in-vmm.txt"; say $? "and the VMM is listening on the host for it"
[ "$r1" = 0 ]; say $? "a host program connected in and got an answer"
grep -qa "HELLO FROM THE HOST" "$out/in1.log"; say $? "which the guest made from the bytes the host sent"
[ "$r2" = 0 ]; say $? "and a second connection worked too"
grep -qa "AND AGAIN" "$out/in2.log"; say $? "with its own, different answer"
grep -qa "] userspace: vsock_server exit 0:" "$ic"; say $? "the guest server served both and exited cleanly"
grep -qa "Initramfs unpacking failed" "$ic" \
  && { echo "  FAIL  the initramfs was truncated"; fail=1; } \
  || echo "  ok    the initramfs unpacked whole"
grep -qa "gave up at the deadline" "$out/in-vmm.txt" \
  && { echo "  FAIL  the inward run ended at the deadline"; fail=1; } \
  || echo "  ok    before the deadline"

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

echo "== poison: let nothing look at the host end =="
# The bug this reproduces was real and cost the first three runs: the loop
# polled the host end only on exits it stopped receiving once the virtual timer
# was masked -- 4 polls in 52,189 exits. Everything up to the guest's write
# still worked, so a check that stopped at "the stream opened" was green.
#
# IT TAKES TWO CUTS NOW, and that is a change in the design rather than a
# weakening of the check. The devices moved to a thread of their own, and that
# thread looks at the host end on its own timeout as well as when it is woken.
# So removing the wake-up alone no longer loses the reply -- it delays it --
# and this poison said so: "the reply arrived anyway". What must still be true
# is that SOMETHING looks, so the poison removes both: no wake-up, and a
# timeout long enough to be no timeout at all.
sed 's|let _ = hv_vs_wake () in|let _ = 0 in|' "$here/vsock.mere" > "$out/poison-vsock.mere"
cmp -s "$here/vsock.mere" "$out/poison-vsock.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cp "$here/virtio.mere" "$out/virtio.mere"
cp "$here/boot.mere" "$out/poison-boot.mere"
sed -i '' 's|import "vsock.mere";|import "poison-vsock.mere";|' "$out/poison-boot.mere"
sed -i '' 's|let cpu = hv_dev_take 20 in|let cpu = hv_dev_take 3600000 in|' "$out/poison-boot.mere"
grep -q "hv_dev_take 3600000" "$out/poison-boot.mere" \
  || { echo "  FAIL  the second half of the poison did not apply"; fail=1; }
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
  grep -qa "^mvm: vsock outward stream, guest port" "$out/poison2-vmm.txt"; say $? "the stream still opens without the wake-up"
  grep -qa "HELLO FROM THE GUEST" "$out/poison2-console.txt" \
    && { echo "  FAIL  the reply arrived with nothing looking at the host end"; fail=1; } \
    || echo "  ok    but the reply never reaches the guest, and this gate sees it"
else
  echo "  FAIL  the poisoned VMM did not build"; fail=1
fi

echo "== poison: start the inward handshake from the wrong end =="
# The inward direction is NOT the outward one with the arguments swapped, and
# this is the mistake that says so: the VMM answers as though the guest had
# asked, instead of asking. Everything else is untouched -- the host connects,
# a stream is allocated, a packet goes onto the receive queue -- and no
# connection is ever made.
sed 's|if vs_ctl s i op_request 0 < 0 then|if vs_ctl s i op_response 0 < 0 then|' \
  "$here/vsock.mere" > "$out/poison3-vsock.mere"
cmp -s "$here/vsock.mere" "$out/poison3-vsock.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cp "$here/virtio.mere" "$out/virtio.mere"
sed 's|import "vsock.mere";|import "poison3-vsock.mere";|' "$here/boot.mere" > "$out/poison3-boot.mere"
if "$M" -c "$out/poison3-boot.mere" > "$out/p3.c" 2>/dev/null \
   && cc -O2 -o "$out/mvm-poison3" "$out/p3.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null; then
  codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-poison3" 2>/dev/null
  rm -f "$IN"
  ( MVM_VSOCK_IN="$IN" MVM_VSOCK_PORT=1024 MVM_TIMEOUT_MS=12000 \
      "$out/mvm-poison3" "$IMAGE_FILE" "$out/vsock-in.dtb" "$out/initrd-vsock-in.gz" \
      > "$out/poison3-console.txt" 2> "$out/poison3-vmm.txt" ) &
  vmpid=$!
  python3 "$here/test/vsock_in.py" "$IN" "hello from the host" 8 > "$out/poison3.log" 2>&1
  r3=$?
  wait "$vmpid" 2>/dev/null
  grep -qa "^mvm: vsock inward stream, host port" "$out/poison3-vmm.txt"
  say $? "the host still reaches the VMM and a stream is still allocated"
  [ "$r3" = 0 ] && { echo "  FAIL  the host got an answer from the wrong handshake"; fail=1; } \
    || echo "  ok    but the guest never accepts, and this gate sees it"
else
  echo "  FAIL  the poisoned VMM did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "vsock PASS" || echo "vsock FAIL"
exit "$fail"
