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
MREG_SRC="${MREG_SRC:-}"
[ -n "$MREG_SRC" ] && [ -f "$MREG_SRC/mreg.mere" ] || { echo "set MREG_SRC=<path to a 284km/mreg checkout>" >&2; exit 2; }
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
# How long the guest stays up. An upper bound, not a cost: the gate kills the
# VM when it is done. It has to outlast everything below, and 45 did not --
# the run died in the middle of creating a container and four checks went red
# for a reason that had nothing to do with what they were checking.
SECS="${SECS:-240}"
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
"$M" -c "$here/guest/mfwd.mere" > "$out/mfwd.c" 2>"$out/e5" || { echo FAIL mfwd emit; sed -n 1,8p "$out/e5"; exit 1; }
docker run --rm -v "$out:/o" -v "$here/guest:/g:ro" -w /o "$IMG" \
  cc -O2 -static -o /o/mfwd-linux /o/mfwd.c /g/fwd_shim.c >/dev/null 2>&1
cp "$out/mfwd-linux" "$out/extra-mengd/mfwd"
"$M" -c "$here/mports.mere" > "$out/mports.c" 2>"$out/e6" || { echo FAIL mports emit; sed -n 1,8p "$out/e6"; exit 1; }
cc -O2 -o "$out/mports" "$out/mports.c" "$here/mports_shim.c" 2>/dev/null || { echo FAIL cc mports; exit 1; }
"$M" -c "$MREG_SRC/mreg.mere" > "$out/mreg.c" 2>"$out/e7" || { echo FAIL mreg emit; sed -n 1,8p "$out/e7"; exit 1; }
cc -O2 -o "$out/mreg" "$out/mreg.c" "$MREG_SRC/reg_shim.c" 2>/dev/null || { echo FAIL cc mreg; exit 1; }
chmod 755 "$out/extra-mengd/mengd" "$out/extra-mengd/mrun" "$out/extra-mengd/mfwd"

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

ROOTARGS="earlycon=pl011,0x9000000 console=ttyAMA0 panic=-1 root=/dev/vda rw init=/sbin/init MENGD_SECONDS=$SECS MVM_FWD_OUT=5000:5000"
# Stopping one has to stop the PROCESS, not the shell that started it. `( cmd )
# &` gives back the subshell's pid, and killing that can leave the VM running --
# which is not a tidy-up problem: the next section binds the same host port,
# fails, and the OLD guest answers it. A poison then passes because the machine
# it was meant to break is not the machine being asked.
stop_vm() {
  if [ -n "${MREGPID:-}" ]; then kill "$MREGPID" 2>/dev/null; wait "$MREGPID" 2>/dev/null; MREGPID=""; fi
  if [ -n "${MPPID:-}" ]; then kill "$MPPID" 2>/dev/null; wait "$MPPID" 2>/dev/null; MPPID=""; fi
  if [ -n "${VMPID:-}" ]; then
    kill "$VMPID" 2>/dev/null
    wait "$VMPID" 2>/dev/null
    VMPID=""
  fi
  # And escalate. A VMM sitting inside the framework's run() does not always
  # go on the first signal, and the next section binds this same port: a bind
  # that fails leaves the OLD guest answering, which is how a poison passes
  # against a machine that was never poisoned.
  i=0
  while [ "$i" -lt 8 ] && lsof -nP -iTCP:18080 >/dev/null 2>&1; do sleep 0.25; i=$((i + 1)); done
  if lsof -nP -iTCP:18080 >/dev/null 2>&1; then
    lsof -t -nP -iTCP:18080 2>/dev/null | while read -r pid; do kill -9 "$pid" 2>/dev/null; done
    i=0
    while [ "$i" -lt 20 ] && lsof -nP -iTCP:18080 >/dev/null 2>&1; do sleep 0.25; i=$((i + 1)); done
  fi
  lsof -nP -iTCP:18080 >/dev/null 2>&1 && echo "  WARN  host port 18080 is still held" || true
  rm -f "$out/mvm.ctl"
}

boot_it() {  # boot_it <mvm binary> <dtb> <disk> <console> <vmm log> <socket>
  rm -f "$6"
  # The docker socket, and one forwarded port. The host's end of a published
  # port has to be open before the VM starts, because opening it is the host's
  # job and nothing in the guest can ask for it yet -- so the number is agreed
  # in advance, and the convention that needs no other agreement is that the
  # vsock port IS the published host port.
  # An outward route as well: the guest has no network, and the registry it
  # pulls from is on this machine. 5000 both sides, by the same convention the
  # published ports use -- whoever opened the host's end chose the number.
  MVM_VSOCK_IN="$6=1024,tcp:18080=18080" MVM_VSOCK_OUT="5000=tcp:5000" \
  MVM_CONTROL="$out/mvm.ctl" \
  MVM_TIMEOUT_MS=$((SECS * 1000 + 60000)) \
      "$1" "$IMAGE_FILE" "$2" "" "$3" > "$4" 2> "$5" &
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
vmmlog="$out/stack-vmm.txt"
grep -qa "] userspace: the amba bus enumerated 9010000.pl031" "$c"
say $? "the guest's amba bus read this VMM's PL031 identity registers"
grep -qa "] userspace: clock says $(date -u +%Y)-" "$c"
say $? "and the guest knows what year it is"
# The memory size is written in two places -- the tree the guest reads and the
# mapping the VMM makes -- and they disagreed once, silently, because 4 GiB
# does not fit in one 32-bit device tree cell. Only the guest can say which
# number it was actually given.
want_k=$(( ${MVM_RAM_MB:-4096} * 1024 ))
grep -qa "] Memory: .*/${want_k}K available" "$c"
say $? "the guest was given the ${want_k}K the VMM mapped"

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
echo "== docker compose up =="
mkdir -p "$out/compose"
cat > "$out/compose/compose.yaml" <<'YAML'
services:
  hello:
    image: alpine:latest
    command: ["echo", "hello-from-compose"]
YAML
co=$( cd "$out/compose" && DOCKER_HOST= docker -H "unix://$SOCK" compose up 2>&1 )
echo "$co" | grep -q "hello-from-compose"; say $? "compose creates a network, runs the service and streams its output"
echo "$co" | grep -q "exited with code 0"; say $? "and reports how it ended"

echo "== a published port, reached from the host =="
# The container listens inside its own network namespace, inside a VM with no
# network interface at all. Everything between the host's TCP port and that
# listener is this project's: the VMM's inward mapping, the vsock stream, and a
# forwarder that enters the container's namespace to make the last hop.
runout=$(d run -d --name web -p 18080:8080 alpine:latest \
  sh -c 'while true; do echo hello-from-the-container | nc -l -p 8080; done' 2>&1)
rc=$?
[ "$rc" = 0 ]; say $? "docker run -p starts a container that listens"
[ "$rc" = 0 ] || echo "        $runout"
d ps --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:18080->8080/tcp"
say $? "docker ps reports the mapping"
ans=""
for try in 1 2 3 4 5; do
  ans=$(echo | nc -w 3 127.0.0.1 18080 2>/dev/null | head -1)
  [ -n "$ans" ] && break
  sleep 1
done
[ "$ans" = "hello-from-the-container" ]; say $? "and the host reaches it through the port ($ans)"
# What proves the forwarder ran in the CONTAINER's namespace is the answer
# arriving at all -- the poison at the end of this file takes the namespace
# entry away and nothing answers. The daemon's own log line would be better
# evidence and cannot be used: the guest's console is /dev/kmsg and the kernel
# rate-limits it, so a busy daemon's lines are exactly the ones dropped.

echo "== a port nobody arranged in advance =="
# 19090 appears nowhere: not in MVM_VSOCK_IN, not on any command line. The
# container asks for it, mports notices, and the VMM opens the host's end --
# which is the one thing neither the VMM nor the guest can decide alone.
lsof -nP -iTCP:19090 >/dev/null 2>&1 && { echo "  FAIL  19090 was already open before anything asked"; fail=1; } \
  || echo "  ok    19090 is not open before anything asks for it"
"$out/mports" "$SOCK" "$out/mvm.ctl" 400 > "$out/mports.log" 2>&1 &
MPPID=$!
d run -d --name web9 -p 19090:8080 alpine:latest \
  sh -c 'while true; do echo hello-from-19090 | nc -l -p 8080; done' >/dev/null 2>&1
say $? "a container publishes it"
i=0; while [ "$i" -lt 30 ] && ! lsof -nP -iTCP:19090 >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
lsof -nP -iTCP:19090 >/dev/null 2>&1; say $? "and the host's end opens on its own"
ans9=""
for try in 1 2 3 4 5; do
  ans9=$(echo | nc -w 3 127.0.0.1 19090 2>/dev/null | head -1)
  [ -n "$ans9" ] && break
  sleep 1
done
[ "$ans9" = "hello-from-19090" ]; say $? "the container answers through it ($ans9)"
grep -q "LISTEN 19090 -> ok listening 19090" "$out/mports.log"; say $? "and the VMM said so on its control socket"
d rm -f web9 >/dev/null 2>&1
i=0; while [ "$i" -lt 30 ] && lsof -nP -iTCP:19090 >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
lsof -nP -iTCP:19090 >/dev/null 2>&1 && { echo "  FAIL  the port outlived the container"; fail=1; } \
  || echo "  ok    and closes again when the container goes"
kill "$MPPID" 2>/dev/null; wait "$MPPID" 2>/dev/null; MPPID=""

echo "== pulling from a registry on the host =="
# The guest has no network interface at all, so a registry is reached the only
# way anything outside is: over vsock. mreg runs here, the guest's forwarder
# carries 127.0.0.1:5000 out, and the VMM decides where that vsock port leads.
#
# Seeded over the distribution API rather than with `docker push`, because the
# daemon that would do the pushing lives in a virtual machine of its own where
# "localhost" is that machine and not this one.
rm -rf "$out/regroot"; mkdir -p "$out/regroot"
"$out/mreg" 5000 "$out/regroot" > "$out/mreg.log" 2>&1 &
MREGPID=$!
i=0; while [ "$i" -lt 40 ] && ! curl -s -o /dev/null "http://127.0.0.1:5000/v2/"; do sleep 0.25; i=$((i + 1)); done
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:5000/v2/" | grep -q 200
say $? "a registry is running on the host"
python3 "$here/tools/seed-registry.py" "$out/alpine.tar" http://127.0.0.1:5000 gate/alpine v1 > "$out/seed.log" 2>&1
say $? "seeded with an image, over the distribution API"
pulled=$(d pull 127.0.0.1:5000/gate/alpine:v1 2>&1 | tail -1)
case "$pulled" in *gate/alpine:v1*) echo "  ok    docker pull, out of that registry and into the VM";; \
                  *) echo "  FAIL  docker pull: $pulled"; fail=1;; esac
d images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^127.0.0.1:5000/gate/alpine:v1$"
say $? "the pulled image is listed"
po=$(d run --network host 127.0.0.1:5000/gate/alpine:v1 echo pulled-and-ran-in-mvm 2>/dev/null)
[ "$po" = "pulled-and-ran-in-mvm" ]; say $? "and a container runs from it ($po)"
# A name rather than an address: this guest has no resolver, and the daemon has
# to say which of the two things went wrong rather than "cannot fetch".
# It went out through the VMM's route rather than some other way. Without this
# the section would pass against a guest that had a network after all.
grep -qa "^mvm: vsock outward stream, guest port .* to port 5000 -> tcp:5000" "$vmmlog"
say $? "the bytes left through the route this VMM was given"
byname=$(d pull localhost:5000/gate/alpine:v1 2>&1 | tail -1)
case "$byname" in *"cannot resolve that name"*) echo "  ok    and a name it cannot resolve is refused by name";; \
                  *) echo "  FAIL  a name gave: $byname"; fail=1;; esac

echo "== a client that hangs up must not take the VMM with it =="
# The default action for SIGPIPE is to kill the process, and a VMM that dies
# because a CLIENT hung up takes the guest and every other connection with it.
# `docker compose up` abandons its /events connection when it exits, so this is
# not a hypothetical: it looked exactly like the daemon inside the VM crashing,
# and every check up to that point was green.
curl -s --unix-socket "$SOCK" "http://localhost/events" >/dev/null 2>&1 &
cpid=$!
sleep 2
kill -9 "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
sleep 1
v2=$(d version --format '{{.Server.Version}}' 2>&1)
[ "$v2" = "0.1.0" ]; say $? "the VMM survives a client that abandons a streaming connection"
grep -qa "^mvm: vsock host write failed" "$vmmlog"; say $? "and says so rather than dying silently"

echo "== what cannot be published is refused by name =="
wr=$(DOCKER_HOST= curl -s --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
      -d '{"Image":"alpine:latest","Cmd":["true"],"HostConfig":{"PortBindings":{"9999/udp":[{"HostPort":"19999"}]}}}' \
      "http://localhost/v1.43/containers/create" 2>/dev/null)
echo "$wr" | grep -q "only tcp is forwarded"
say $? "a udp publish comes back as a warning that names it"
stop_vm

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
    # The bytes EXISTED -- which is what makes this a lost write rather than a
    # container that printed nothing. Asked through the API rather than read
    # off the console, because the console is rate-limited and a check that
    # cannot see its subject is not a check.
    pcid=$(d ps -aq 2>/dev/null | head -1)
    d logs "$pcid" 2>/dev/null | grep -q "poisoned-output" \
      && echo "  ok    while docker logs shows the container did print them" \
      || { echo "  FAIL  the container printed nothing, so this poison proves nothing"; fail=1; }
    stop_vm
  else
    echo "  FAIL  the poisoned VMM did not bring the daemon up"; fail=1
    stop_vm
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
  MVM_VSOCK_IN="$SOCK" MVM_VSOCK_PORT=1024 MVM_TIMEOUT_MS=$((SECS * 1000 + 60000)) \
      "$out/mvm-boot" "$IMAGE_FILE" "$out/initrd-mengd.dtb" "$out/initrd-mengd.gz" \
      > "$out/pinit-console.txt" 2> "$out/pinit-vmm.txt" &
  VMPID=$!
  i=0; while [ "$i" -lt 240 ] && ! grep -qa "listening on" "$out/pinit-console.txt" 2>/dev/null; do sleep 0.5; i=$((i+1)); done
  grep -qa "listening on" "$out/pinit-console.txt"; say $? "the daemon comes up there too"
  d load -i "$out/alpine.tar" >/dev/null 2>&1; say $? "and still loads an image"
  d run --network host alpine:latest echo should-not-appear >/dev/null 2>&1
  pcid=$(d ps -aq 2>/dev/null | head -1)
  perr=$(d logs "$pcid" 2>&1 | head -1)
  case "$perr" in *pivot_root*) echo "  ok    but the runtime cannot enter a container ($perr)";;
                  *) echo "  FAIL  expected a pivot_root refusal, got: $perr"; fail=1;; esac
  stop_vm
else
  echo "  FAIL  the initramfs did not build"; fail=1
fi

echo "== poison: forward into the guest's namespace instead of the container's =="
# The last hop is the one that is easy to get wrong and easy to not notice: a
# forwarder that connects from the guest's own namespace finds nothing, because
# the container's loopback is not the guest's. Everything before it still
# works -- the host port opens, the stream arrives, the daemon reports the
# mapping -- so only the answer is missing.
sed 's|let up = fw_connect_in pid lport in|let up = fw_connect_in 0 lport in|' \
  "$here/guest/mfwd.mere" > "$out/poison-mfwd.mere"
cmp -s "$here/guest/mfwd.mere" "$out/poison-mfwd.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
if "$M" -c "$out/poison-mfwd.mere" > "$out/pm.c" 2>/dev/null \
   && docker run --rm -v "$out:/o" -v "$here/guest:/g:ro" -w /o "$IMG" \
        cc -O2 -static -o /o/mfwd-poison /o/pm.c /g/fwd_shim.c >/dev/null 2>&1; then
  cp "$out/extra-mengd/mfwd" "$out/mfwd-good"
  cp "$out/mfwd-poison" "$out/extra-mengd/mfwd"
  sh "$here/tools/mkrootfs.sh" "$out/rootfs-pn.img" 512 "$out/extra-mengd" >/dev/null 2>&1
  cp "$out/mfwd-good" "$out/extra-mengd/mfwd"
  if boot_it "$out/mvm-boot" "$out/stack.dtb" "$out/rootfs-pn.img" \
             "$out/pns-console.txt" "$out/pns-vmm.txt" "$SOCK"; then
    d load -i "$out/alpine.tar" >/dev/null 2>&1
    d run -d --name web2 -p 18080:8080 alpine:latest \
      sh -c 'while true; do echo hello-from-the-container | nc -l -p 8080; done' >/dev/null 2>&1
    say $? "the container still starts"
    sleep 3
    pans=$(echo | nc -w 3 127.0.0.1 18080 2>/dev/null | head -1)
    [ "$pans" = "hello-from-the-container" ] \
      && { echo "  FAIL  the answer arrived anyway, so this gate does not depend on the namespace entry"; fail=1; } \
      || echo "  ok    but nothing answers on the port, and this gate sees it"
    grep -qa "nothing listening on 127.0.0.1:8080" "$out/pns-console.txt" "$out/extra-mengd/fwd.log" 2>/dev/null \
      || true
    stop_vm
  else
    echo "  FAIL  the poisoned guest did not bring the daemon up"; fail=1
    stop_vm
  fi
else
  echo "  FAIL  the poisoned forwarder did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "stack PASS" || echo "stack FAIL"
exit "$fail"
