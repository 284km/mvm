#!/bin/sh
# test/hub.sh — a container image pulled from Docker Hub, from inside the VM.
#
# WHAT IT NEEDS, and why this is not a skip. Docker Hub, over the internet, and
# a `docker` for the oracle. A check that cannot run is not a check that
# passed, so a missing network fails this file. It is separate from
# test/stack.sh for the same reason: that one runs offline and should keep
# doing so.
#
# WHAT IS BEING JUDGED. Not that mengd can pull from Hub -- its own test/hub.sh
# does that, on a machine with a network. Here the daemon is inside a VM with
# NO network interface at all, so every byte goes over vsock, and the blobs are
# redirected to a content network whose host nobody knew when the machine
# started. That last part is why there is a proxy and not a bigger table.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"; MENGD_SRC="${MENGD_SRC:-}"; MRUN_SRC="${MRUN_SRC:-}"
[ -n "$MERE" ] || { echo "set MERE=<a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
[ -n "$MENGD_SRC" ] && [ -f "$MENGD_SRC/mengd.mere" ] || { echo "set MENGD_SRC=<a 284km/mengd checkout>" >&2; exit 2; }
[ -n "$MRUN_SRC" ] && [ -f "$MRUN_SRC/mrun.mere" ] || { echo "set MRUN_SRC=<a 284km/mrun checkout>" >&2; exit 2; }
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs docker, for the oracle" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
IMAGE_FILE="${IMAGE_FILE:-$out/Image}"
[ -r "$IMAGE_FILE" ] || { echo "no kernel at $IMAGE_FILE" >&2; exit 2; }
VSMOD="${VSMOD:-$out/extra}"
[ -r "$VSMOD/vsock.ko" ] || { echo "no vsock modules in $VSMOD -- see test/vsock.sh" >&2; exit 2; }
IMG="${IMG:-gcc:14}"
# A build that installs a package takes a while, and the guest's own clock is
# what ends the run.
SECS="${SECS:-420}"
REF="${REF:-docker.io/library/alpine:latest}"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== the internet is there =="
curl -s -o /dev/null -m 15 -w '%{http_code}' https://registry-1.docker.io/v2/ | grep -q 401
say $? "Docker Hub answers, and asks for authentication"

echo "== build =="
BUILD_IMG="mvm-build:1"
docker image inspect "$BUILD_IMG" >/dev/null 2>&1 || docker build -q -t "$BUILD_IMG" - >/dev/null 2>&1 <<DOCKERFILE
FROM $IMG
RUN apt-get -qq update && apt-get -qq install -y libssl-dev zlib1g-dev libzstd-dev \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
mkdir -p "$out/extra-hub" "$MENGD_SRC/.build" "$MRUN_SRC/.build"
"$M" -c "$MENGD_SRC/mengd.mere" > "$MENGD_SRC/.build/mengd.c" 2>"$out/e1" || { echo FAIL mengd emit; sed -n 1,8p "$out/e1"; exit 1; }
"$M" -c "$MRUN_SRC/mrun.mere"   > "$MRUN_SRC/.build/mrun.c"   2>"$out/e2" || { echo FAIL mrun emit;  sed -n 1,8p "$out/e2"; exit 1; }
"$M" -c "$here/guest/mfwd.mere" > "$out/mfwd.c"               2>"$out/e3" || { echo FAIL mfwd emit;  sed -n 1,8p "$out/e3"; exit 1; }
"$M" -c "$here/mproxy.mere"     > "$out/mproxy.c"             2>"$out/e4" || { echo FAIL mproxy emit; sed -n 1,8p "$out/e4"; exit 1; }
"$M" -c "$here/mkdtb.mere"      > "$out/mkdtb.c"              2>"$out/e5" || { echo FAIL mkdtb emit; exit 1; }
"$M" -c "$here/boot.mere"       > "$out/boot.c"               2>"$out/e6" || { echo FAIL boot emit;  exit 1; }
docker run --rm -v "$MENGD_SRC:/w" -w /w "$BUILD_IMG" cc -O2 -static -o .build/mengd-linux \
  .build/mengd.c unix_shim.c fs_shim.c store_shim.c -lssl -lcrypto -lz -lzstd -ldl -lpthread >/dev/null 2>&1
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c >/dev/null 2>&1
docker run --rm -v "$out:/o" -v "$here/guest:/g:ro" -w /o "$IMG" cc -O2 -static -o /o/mfwd-linux /o/mfwd.c /g/fwd_shim.c >/dev/null 2>&1
cc -O2 -o "$out/mproxy"   "$out/mproxy.c" "$here/proxy_shim.c" 2>/dev/null || { echo FAIL cc mproxy; exit 1; }
cc -O2 -o "$out/mkdtb"    "$out/mkdtb.c"  "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc mkdtb; exit 1; }
cc -O2 -o "$out/mvm-boot" "$out/boot.c"   "$here/hv_shim.c" -framework Hypervisor 2>/dev/null || { echo FAIL cc boot; exit 1; }
for b in mkdtb mvm-boot; do codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/$b" 2>/dev/null; done
cp "$VSMOD"/*.ko "$out/extra-hub/" 2>/dev/null
cp "$MENGD_SRC/.build/mengd-linux" "$out/extra-hub/mengd"
cp "$MRUN_SRC/.build/mrun-linux"   "$out/extra-hub/mrun"
cp "$out/mfwd-linux"               "$out/extra-hub/mfwd"
# The public roots, because what it is verifying is Docker Hub's certificate.
cp /etc/ssl/cert.pem "$out/extra-hub/ca.pem"
chmod 755 "$out/extra-hub/mengd" "$out/extra-hub/mrun" "$out/extra-hub/mfwd"
[ -x "$out/extra-hub/mengd" ] && [ -x "$out/mproxy" ]; say $? "everything builds, with TLS"

echo "== the machine =="
MPROXY_TRACE=1 "$out/mproxy" 3128 > "$out/mproxy.log" 2>&1 &
PXPID=$!
sleep 1
curl -s -x http://127.0.0.1:3128 -o /dev/null -m 20 -w '%{http_code}' https://registry-1.docker.io/v2/ | grep -q 401
say $? "the proxy on this machine tunnels to Hub"
MVM_BOOTARGS="earlycon=pl011,0x9000000 console=ttyAMA0 panic=-1 root=/dev/vda rw init=/sbin/init MENGD_SECONDS=$SECS MVM_FWD_OUT=3128:3128 MENGD_PROXY=127.0.0.1:3128" \
  "$out/mkdtb" "$out/hub.dtb" >/dev/null 2>&1
sh "$here/tools/mkrootfs.sh" "$out/rootfs-hub.img" 512 "$out/extra-hub" >/dev/null 2>&1
SOCK="$out/hub-docker.sock"; rm -f "$SOCK"
MVM_VSOCK_IN="$SOCK=1024" MVM_VSOCK_OUT="3128=tcp:3128" MVM_TIMEOUT_MS=$((SECS * 1000 + 60000)) \
  "$out/mvm-boot" "$IMAGE_FILE" "$out/hub.dtb" "" "$out/rootfs-hub.img" \
  > "$out/hub-console.txt" 2> "$out/hub-vmm.txt" &
VMPID=$!
i=0; while [ "$i" -lt 240 ] && ! grep -qa "listening on" "$out/hub-console.txt" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
grep -qa "listening on" "$out/hub-console.txt"; say $? "the daemon is up inside the VM"
# It really has no way out other than the one it was given.
grep -qa "] userspace: outward forwarders started for 3128:3128" "$out/hub-console.txt"
say $? "and one outward route, to that proxy"

export DOCKER_HOST=
d() { docker -H "unix://$SOCK" "$@"; }

echo "== pull, from inside =="
got=$(d pull "$REF" 2>&1 | tail -1)
[ "$got" = "$REF" ]; say $? "docker pull $REF ($got)"
grep -qa "^mvm: vsock outward stream, guest port .* to port 3128 -> tcp:3128" "$out/hub-vmm.txt"
say $? "every byte of it left through the VMM's one route"
grep -qa "mproxy: " "$out/mproxy.log" 2>/dev/null || true
o=$(d run --network host "$REF" echo pulled-hub-inside-mvm 2>/dev/null)
[ "$o" = "pulled-hub-inside-mvm" ]; say $? "and a container runs from it ($o)"

# The oracle: the config digest of the arm64 manifest out of what the real
# client downloaded for the same reference. Not `docker image inspect .Id`,
# which answers the index digest on a daemon with a containerd image store and
# the config digest on one without -- a different question depending on where
# it is asked.
docker pull -q "$REF" >/dev/null 2>&1
docker save "$REF" -o "$out/hub-oracle.tar" 2>/dev/null
cat > "$out/config_digest.py" <<'ORACLE'
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    blob = lambda d: t.extractfile("blobs/" + d.replace(":", "/")).read()
    top = json.loads(t.extractfile("index.json").read())["manifests"][0]
    doc = json.loads(blob(top["digest"]))
    if "manifests" in doc:
        m = [x for x in doc["manifests"]
             if x.get("platform", {}).get("architecture") == "arm64"
             and x.get("platform", {}).get("os") == "linux"][0]
        doc = json.loads(blob(m["digest"]))
    print(doc["config"]["digest"].split(":")[1][:12])
ORACLE
want=$(python3 "$out/config_digest.py" "$out/hub-oracle.tar" 2>/dev/null)
mine=$(d images --format '{{.ID}}' 2>/dev/null | head -1)
[ -n "$want" ] && [ "$want" = "$mine" ]
say $? "the image id is the config digest docker downloaded for it ($mine vs $want)"

echo "== a build whose steps need the network =="
# The daemon reaching a registry and a CONTAINER reaching a package mirror are
# different paths: one is the daemon's own socket, the other is a tool inside a
# container in a machine with no network. This is the second.
mkdir -p "$out/nctx"
cat > "$out/nctx/Dockerfile" <<'DF'
FROM docker.io/library/alpine:latest
RUN apk add --no-cache curl && echo apk-ok
RUN curl -sS -o /got.txt https://example.com/ && echo curl-ok
CMD ["head", "-1", "/got.txt"]
DF
( cd "$out/nctx" && DOCKER_BUILDKIT=0 DOCKER_HOST= docker -H "unix://$SOCK" build -t netbuild:v1 .     > "$out/netbuild.log" 2>&1 )
say $? "docker build, with steps that install and fetch"
grep -q "apk-ok" "$out/netbuild.log"; say $? "a package manager reached its mirror"
grep -q "curl-ok" "$out/netbuild.log"; say $? "and a tool fetched over TLS"
bo=$(d run --network host netbuild:v1 2>/dev/null | head -1)
case "$bo" in *"Example Domain"*) echo "  ok    and the image it built has what it fetched";;                *) echo "  FAIL  the built image printed: $bo"; fail=1;; esac
grep -q "mproxy: dl-cdn.alpinelinux.org:443" "$out/mproxy.log"
say $? "the package mirror was reached through the proxy, not some other way"

# What the proxy will NOT do, and says so. busybox's wget has no CONNECT: it
# asks the proxy to fetch, which for https would mean this end doing the TLS
# and the caller verifying nothing.
wo=$(curl -s -x http://127.0.0.1:3128 http://example.com/ 2>&1 | head -1)
case "$wo" in *"does not fetch on your behalf"*) echo "  ok    and a client that asks it to fetch is told why not";;                *) echo "  FAIL  got: $wo"; fail=1;; esac

kill "$VMPID" 2>/dev/null; wait "$VMPID" 2>/dev/null
kill "$PXPID" 2>/dev/null; wait "$PXPID" 2>/dev/null
[ "$fail" = 0 ] && echo "hub PASS" || echo "hub FAIL"
exit "$fail"
