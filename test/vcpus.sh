#!/bin/sh
# test/vcpus.sh — more than one CPU, and what it is for.
#
# WHY THIS EXISTS. Every other check runs the default, which is one CPU, and
# would stay green if the second one never started. This one asks the guest how
# many it has, and then asks the question that made it worth building: does a
# busy neighbour still make the web service slow?
#
# THE MEASUREMENT IT ENCODES, taken before any of it was written:
#
#   worker      1 vCPU   2 vCPU   4 vCPU   colima (6)
#   none        100 ms   101 ms    99 ms     109 ms
#   1           239 ms    97 ms   104 ms     111 ms
#   3           530 ms   269 ms   100 ms     127 ms
#
# One vCPU is not slow -- it is slow WHEN SOMETHING ELSE IS RUNNING, which is
# what a web service next to a worker is. That is the contract here.
#
#   MERE=<mere> MENGD_SRC=<mengd> MRUN_SRC=<mrun> sh test/vcpus.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client as the oracle" >&2; exit 2; }
[ -n "${MENGD_SRC:-}" ] && [ -n "${MRUN_SRC:-}" ] || { echo "set MENGD_SRC and MRUN_SRC" >&2; exit 2; }
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
M="cpu$$"
export MVM_HOME="${MVM_HOME:-$HOME/.mvm}"
D="$MVM_HOME/$M"
out="$here/.build"; mkdir -p "$out"
PORT="${PORT:-8123}"
cleanup() {
  [ -d "$D" ] && cp "$D/vmm.log" "$out/vcpus-$M-vmm.log" 2>/dev/null
  sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
  rm -rf "$D"; docker context rm "mvm-$M" >/dev/null 2>&1
}
trap cleanup EXIT
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

echo "== four CPUs =="
MVM_VCPUS=4 sh "$here/tools/mvm" start --name "$M" --disk-size 4096 > "$out/vcpus-start.log" 2>&1
say $? "mvm start with MVM_VCPUS=4"
grep -q "4 cpus" "$out/vcpus-start.log" || grep -qa "4 cpus" "$D/vmm.log" 2>/dev/null
say $? "the VMM says so"
# THE GUEST IS THE ONE THAT HAS TO HAVE THEM. A VMM that creates four vCPUs and
# a guest that finds one is the failure this cannot miss, and only the guest
# can tell them apart.
grep -qa "SMP: Total of 4 processors activated" "$D/console.log"
say $? "and Linux brought up four"

export DOCKER_HOST="unix://$D/docker.sock"
export DOCKER_CONTEXT=
DOCKER_HOST= docker save alpine:latest -o "$out/vcpus-alpine.tar" 2>/dev/null
docker load -i "$out/vcpus-alpine.tar" >/dev/null 2>&1; say $? "an image loads"
n=$(docker run --rm alpine:latest nproc 2>/dev/null | tr -d '\r\n')
[ "$n" = 4 ]; say $? "a container sees four ($n)"

echo "== a service next to a busy neighbour =="
docker network create appnet >/dev/null 2>&1
# A handler that uses the CPU, because that is the case that contends: a
# service that only waits on I/O is not slowed by a neighbour even on one vCPU
# -- measured at 45 ms with none and 45 ms with three.
docker run -d --name web --network appnet -p "$PORT:80" alpine:latest sh -c \
  'while true; do (i=0; while [ $i -lt 120000 ]; do i=$((i+1)); done; printf "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nhi\n") | nc -l -p 80 || sleep 0.1; done' >/dev/null 2>&1
sleep 4
lat() {
  i=0; o=""; bad=0
  while [ "$i" -lt 9 ]; do
    a=$(ms); c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$PORT/" 2>/dev/null); b=$(ms)
    # A FAILED REQUEST IS NOT A FAST ONE. Timing without looking at the status
    # made a dead service look like the quickest one in the table.
    if [ "$c" = 200 ]; then o="$o $((b-a))"; else bad=$((bad+1)); fi
    i=$((i+1))
  done
  [ -z "$o" ] && { echo "0"; return; }
  echo "$o" | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}
idle=$(lat)
[ "$idle" -gt 0 ]; say $? "the service answers ($idle ms with nothing else running)"
i=0; while [ "$i" -lt 3 ]; do
  docker run -d --name wk$i --network appnet alpine:latest sh -c \
    'while true; do i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done; done' >/dev/null 2>&1
  i=$((i + 1))
done
sleep 3
busy=$(lat)
[ "$busy" -gt 0 ]; say $? "and still answers with three workers running ($busy ms)"
# On one vCPU this was 530 against 100 -- five times. Two is generous: it says
# the second CPU is doing something without pinning down a number that belongs
# to this machine on this day.
[ "$busy" -lt $((idle * 2)) ]
say $? "and is not slowed to a crawl by them ($idle ms -> $busy ms, one vCPU was ${idle} -> about 5x)"
for n in $(docker ps -aq --filter name=wk 2>/dev/null); do docker rm -f "$n" >/dev/null 2>&1; done

# A TRAPPED REGISTER IS NAMED ONCE, NOT ONCE PER CPU.
#
# Each CPU runs the same bring-up, so each one trapped the same two debug
# registers, and the VMM said so every time. Four lines became eight; sixty-
# four vCPUs would have made a hundred and twenty-eight, and a register
# trapped inside a LOOP would have had no bound at all -- one stuck vsock
# table once wrote 177,680 lines and 12.9 MB this way.
#
# The invariant does not name a count: however many distinct registers the
# kernel asks about, the log holds each of them exactly once.
echo "== a register this VMM does not model is named once =="
tot=$(grep -c "does not model" "$D/vmm.log" 2>/dev/null | tr -d ' ')
dis=$(grep "does not model" "$D/vmm.log" 2>/dev/null | grep -o "s[0-9]_[0-9]_c[0-9]*_c[0-9]*_[0-9]*" | sort -u | wc -l | tr -d ' ')
[ "${tot:-0}" -gt 0 ] && [ "$tot" = "$dis" ]
say $? "$tot lines for $dis distinct registers, across all four CPUs"

echo "== poison: let it say so every time =="
# Built here rather than trusted from .build: this gate is run on its own as
# often as it is run from all.sh, and a stale boot.c would poison the poison.
MEREX="${MERE:-}/_build/default/bin/mere.exe"
[ -x "$MEREX" ] && "$MEREX" -c "$here/boot.mere" > "$out/vc-boot.c" 2>/dev/null
say $? "boot.mere compiles (MERE must be set for the poison)"
sed 's/if (SYS_SEEN\[i\] == key) { pthread_mutex_unlock(&SYS_M); return 0; }/if (SYS_SEEN[i] == key) { pthread_mutex_unlock(\&SYS_M); return 1; }/' \
  "$here/hv_shim.c" > "$out/vc-poison.c"
cmp -s "$here/hv_shim.c" "$out/vc-poison.c" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cc -O2 -o "$out/mvm-boot-vcpoison" "$out/vc-boot.c" "$out/vc-poison.c" -framework Hypervisor 2>/dev/null \
  && codesign --sign - --force --entitlements "$here/mvm.entitlements" "$out/mvm-boot-vcpoison" 2>/dev/null
say $? "it builds"
P="${M}p"
sh "$here/tools/mvm" stop --name "$P" >/dev/null 2>&1; rm -rf "$MVM_HOME/$P"
MVM_BOOT="$out/mvm-boot-vcpoison" MVM_VCPUS=4 sh "$here/tools/mvm" start --name "$P" \
  --disk-size 2048 > "$out/vc-poison.log" 2>&1
pt=$(grep -c "does not model" "$MVM_HOME/$P/vmm.log" 2>/dev/null | tr -d ' ')
pd=$(grep "does not model" "$MVM_HOME/$P/vmm.log" 2>/dev/null | grep -o "s[0-9]_[0-9]_c[0-9]*_c[0-9]*_[0-9]*" | sort -u | wc -l | tr -d ' ')
[ "${pt:-0}" -gt "${pd:-0}" ]
say $? "and then it repeats itself ($pt lines for $pd registers)"
sh "$here/tools/mvm" stop --name "$P" >/dev/null 2>&1
rm -rf "$MVM_HOME/$P"; docker context rm -f "mvm-$P" >/dev/null 2>&1

[ "$fail" = 0 ] && echo "vcpus PASS" || echo "vcpus FAIL"
exit "$fail"
