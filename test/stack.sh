#!/bin/sh
# test/stack.sh — P6: the whole stack, and a real `docker` client as the oracle.
#
# WHAT IS BEING JUDGED. Not that the pieces exist. That the client a person
# actually types at gets the answers it expects, from a daemon running inside a
# virtual machine this project wrote, on a runtime this project wrote:
#
#   docker (macOS) -> a unix socket -> mvm -> virtio-vsock -> mengd -> mrun
#
# Nothing in that chain after the client is Go, and nothing in it is lima or vz.
#
# WHAT IT NEEDS:
#   MERE=<a merelang/mere checkout>   MENGD_SRC=<284km/mengd>   MRUN_SRC=<284km/mrun>
#   an arm64 Image in .build/, and VSMOD=<dir> with the three vsock modules
#   (see test/vsock.sh for where those come from), and a container runtime.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"; MENGD_SRC="${MENGD_SRC:-}"; MRUN_SRC="${MRUN_SRC:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
[ -n "$MENGD_SRC" ] && [ -f "$MENGD_SRC/mengd.mere" ] || { echo "set MENGD_SRC=<path to a 284km/mengd checkout>" >&2; exit 2; }
[ -n "$MRUN_SRC" ] && [ -f "$MRUN_SRC/mrun.mere" ] || { echo "set MRUN_SRC=<path to a 284km/mrun checkout>" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a container runtime" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
IMAGE_FILE="${IMAGE_FILE:-$out/Image}"
[ -r "$IMAGE_FILE" ] || { echo "no kernel at $IMAGE_FILE" >&2; exit 2; }
VSMOD="${VSMOD:-$out/extra}"
for m in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport; do
  [ -r "$VSMOD/$m.ko" ] || { echo "no $m.ko in $VSMOD -- see test/vsock.sh" >&2; exit 2; }
done
IMG="${IMG:-gcc:14}"
SECS="${SECS:-45}"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build the guest's userspace =="
mkdir -p "$out/extra-mengd" "$MENGD_SRC/.build" "$MRUN_SRC/.build"
"$M" -c "$MENGD_SRC/mengd.mere" > "$MENGD_SRC/.build/mengd.c" 2>"$out/e1" || { echo FAIL mengd emit; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$MRUN_SRC/mrun.mere"   > "$MRUN_SRC/.build/mrun.c"   2>"$out/e2" || { echo FAIL mrun emit;  sed -n 1,8p "$out/e2"; exit 1; }
docker run --rm -v "$MENGD_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mengd-linux .build/mengd.c unix_shim.c fs_shim.c store_shim.c >/dev/null 2>&1
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c >/dev/null 2>&1
[ -x "$MENGD_SRC/.build/mengd-linux" ] && [ -x "$MRUN_SRC/.build/mrun-linux" ]
say $? "mengd and mrun, built for the guest"
cp "$VSMOD"/*.ko "$out/extra-mengd/" 2>/dev/null
cp "$MENGD_SRC/.build/mengd-linux" "$out/extra-mengd/mengd"
cp "$MRUN_SRC/.build/mrun-linux" "$out/extra-mengd/mrun"
chmod 755 "$out/extra-mengd/mengd" "$out/extra-mengd/mrun"

echo "== build the VMM and a root filesystem =="
"$M" -c "$here/mkdtb.mere" > "$out/mkdtb.c" 2>"$out/e3" || { echo FAIL mkdtb; sed -n 1,8p "$out/e3"; exit 1; }
"$M" -c "$here/boot.mere"  > "$out/boot.c"  2>"$out/e4" || { echo FAIL boot;  sed -n 1,8p "$out/e4"; exit 1; }
cc -O2 -o "$out/mkdtb"    "$out/mkdtb.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c"  "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done
sh "$here/tools/mkrootfs.sh" "$out/rootfs.img" 512 "$out/extra-mengd" >/dev/null 2>&1
[ -r "$out/rootfs.img" ]; say $? "an ext4 root filesystem with the daemon in it"
DOCKER_HOST= docker pull -q alpine:latest >/dev/null 2>&1
DOCKER_HOST= docker save alpine:latest -o "$out/alpine.tar" 2>/dev/null
[ -r "$out/alpine.tar" ]; say $? "an image for the guest to load"

ROOTARGS="earlycon=pl011,0x9000000 console=ttyAMA0 panic=-1 root=/dev/vda rw init=/sbin/init MENGD_SECONDS=$SECS"
boot_it() {  # boot_it <mvm binary> <dtb> <disk> <console> <vmm log> <socket>
  rm -f "$6"
  ( MVM_VSOCK_IN="$6" MVM_VSOCK_PORT=1024 MVM_TIMEOUT_MS=$((SECS * 1000 + 60000)) \
      "$1" "$IMAGE_FILE" "$2" "" "$3" > "$4" 2> "$5" ) &
  VMPID=$!
  i=0
  while [ "$i" -lt 240 ]; do
    grep -qa "listening on" "$4" 2>/dev/null && return 0
    kill -0 "$VMPID" 2>/dev/null || return 1
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

echo "== the daemon comes up inside the VM =="
MVM_BOOTARGS="$ROOTARGS" "$out/mkdtb" "$out/stack.dtb" >/dev/null 2>&1
SOCK="$out/docker.sock"
boot_it "$out/mvm-boot" "$out/stack.dtb" "$out/rootfs.img" "$out/stack-console.txt" "$out/stack-vmm.txt" "$SOCK"
say $? "mengd is listening on a vsock port inside the guest"
c="$out/stack-console.txt"
grep -qa "] userspace: the amba bus enumerated 9010000.pl031" "$c"
say $? "the guest's amba bus read this VMM's PL031 identity registers"
grep -qa "] userspace: clock says $(date -u +%Y)-" "$c"
say $? "and the guest knows what year it is"

export DOCKER_HOST=
d() { docker -H "unix://$SOCK" "$@"; }

echo "== a real docker client, against a Mere daemon inside a Mere VMM =="
v=$(d version --format '{{.Server.Version}}/{{.Server.Os}}/{{.Server.Arch}}' 2>&1)
[ "$v" = "0.1.0/linux/arm64" ]; say $? "docker version reports the server ($v)"
d load -i "$out/alpine.tar" 2>&1 | grep -q "Loaded image"; say $? "docker load, 7.8 MB across the vsock stream"
d images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^alpine:latest$"; say $? "docker images lists it"

# The foreground run. This is the one that needs the whole chain at once: the
# client hijacks the connection with Upgrade: tcp, the daemon frames the
# container's output onto it, and the VMM has to carry those bytes back while
# the client has already closed its own write side.
o=$(d run --network host alpine:latest sh -c 'echo to-stdout; echo to-stderr 1>&2' 2>/dev/null)
[ "$o" = "to-stdout" ]; say $? "docker run prints what the container printed ($o)"
e=$(d run --network host alpine:latest sh -c 'exit 7' 2>/dev/null; echo $?)
[ "$e" = 7 ]; say $? "and exits with the container's status ($e)"

cid=$(d ps -aq 2>/dev/null | head -1)
[ -n "$cid" ]; say $? "docker ps -a lists the containers"
created=$(d inspect "$cid" --format '{{.Created}}' 2>/dev/null)
case "$created" in 1970-*) echo "  FAIL  Created is the epoch ($created)"; fail=1;;
                   "$(date -u +%Y)"-*) echo "  ok    Created is a real time ($created)";;
                   *) echo "  FAIL  Created is $created"; fail=1;; esac
kill "$VMPID" 2>/dev/null; wait "$VMPID" 2>/dev/null

echo "== poison: shut down both directions when the client closes its write side =="
# The bug this reproduces cost the longest. `docker run` closes stdin on the
# connection it attached with; read() on the host end then returns 0. Treating
# that as the end of the stream and telling the guest so in BOTH directions
# kills the guest's write side -- and the container's output, which the daemon
# had already framed, is never sent. Everything else still works, which is why
# `docker logs` was green while `docker run` printed nothing.
sed 's|0 op_shutdown 2 (sget s i s_fwd) in|0 op_shutdown 3 (sget s i s_fwd) in|' \
  "$here/vsock.mere" > "$out/poison-stack-vsock.mere"
cmp -s "$here/vsock.mere" "$out/poison-stack-vsock.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cp "$here/virtio.mere" "$out/virtio.mere"
sed 's|import "vsock.mere";|import "poison-stack-vsock.mere";|' "$here/boot.mere" > "$out/poison-stack-boot.mere"
if "$M" -c "$out/poison-stack-boot.mere" > "$out/ps.c" 2>/dev/null \
   && cc -O2 -o "$out/mvm-stack-poison" "$out/ps.c" "$here/hv_shim.c" -framework Hypervisor 2>/dev/null; then
  codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-stack-poison" 2>/dev/null
  sh "$here/tools/mkrootfs.sh" "$out/rootfs-p.img" 512 "$out/extra-mengd" >/dev/null 2>&1
  if boot_it "$out/mvm-stack-poison" "$out/stack.dtb" "$out/rootfs-p.img" \
             "$out/pstack-console.txt" "$out/pstack-vmm.txt" "$SOCK"; then
    d load -i "$out/alpine.tar" >/dev/null 2>&1
    say $? "docker load still works without the fix"
    po=$(d run --network host alpine:latest echo poisoned-output 2>/dev/null)
    [ "$po" = "poisoned-output" ] \
      && { echo "  FAIL  the output arrived anyway, so this gate does not depend on the fix"; fail=1; } \
      || echo "  ok    but docker run prints nothing, and this gate sees it ($po)"
    # And the daemon says it HAD the bytes, which is what makes this a lost
    # write rather than a container that produced nothing.
    grep -qa "attach: framing" "$out/pstack-console.txt" \
      && echo "  ok    while the daemon's own log says it framed them" \
      || { echo "  FAIL  the daemon never framed anything, so this poison proves nothing"; fail=1; }
    kill "$VMPID" 2>/dev/null; wait "$VMPID" 2>/dev/null
  else
    echo "  FAIL  the poisoned VMM did not bring the daemon up"; fail=1
    kill "$VMPID" 2>/dev/null
  fi
else
  echo "  FAIL  the poisoned VMM did not build"; fail=1
fi

echo "== poison: run the daemon on the initramfs instead of a disk =="
# Why there is a disk at all. pivot_root refuses when the current root is the
# initramfs, so a container runtime cannot enter a container there -- and the
# daemon comes up, answers every route, and creates containers that never run.
INIT="$here/initrd/init-mengd" EXTRA="$out/extra-mengd" \
  sh "$here/initrd/build.sh" "$out/initrd-mengd.gz" >/dev/null 2>&1
if [ -r "$out/initrd-mengd.gz" ]; then
  sz=$(stat -f%z "$out/initrd-mengd.gz"); start=$((0x4a000000))
  MVM_BOOTARGS="earlycon=pl011,0x9000000 console=ttyAMA0 panic=-1 rdinit=/init MENGD_SECONDS=$SECS" \
    "$out/mkdtb" "$out/initrd-mengd.dtb" "$start" $((start + sz)) >/dev/null 2>&1
  rm -f "$SOCK"
  ( MVM_VSOCK_IN="$SOCK" MVM_VSOCK_PORT=1024 MVM_TIMEOUT_MS=$((SECS * 1000 + 60000)) \
      "$out/mvm-boot" "$IMAGE_FILE" "$out/initrd-mengd.dtb" "$out/initrd-mengd.gz" \
      > "$out/pinit-console.txt" 2> "$out/pinit-vmm.txt" ) &
  VMPID=$!
  i=0; while [ "$i" -lt 240 ] && ! grep -qa "listening on" "$out/pinit-console.txt" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
  grep -qa "listening on" "$out/pinit-console.txt"; say $? "the daemon comes up there too"
  d load -i "$out/alpine.tar" >/dev/null 2>&1; say $? "and still loads an image"
  d run --network host alpine:latest echo should-not-appear >/dev/null 2>&1
  pcid=$(d ps -aq 2>/dev/null | head -1)
  perr=$(d logs "$pcid" 2>&1 | head -1)
  case "$perr" in *pivot_root*) echo "  ok    but the runtime cannot enter a container ($perr)";;
                  *) echo "  FAIL  expected a pivot_root refusal, got: $perr"; fail=1;; esac
  kill "$VMPID" 2>/dev/null; wait "$VMPID" 2>/dev/null
else
  echo "  FAIL  the initramfs did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "stack PASS" || echo "stack FAIL"
exit "$fail"
