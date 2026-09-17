#!/bin/sh
# test/scale.sh — how many containers, and what is held while they run.
#
# WHY THIS EXISTS. The number this was first measured with was a TOTAL: "25
# containers, 303 seconds". A total cannot tell a slope from a wall, and this
# was a wall -- the first sixteen took 268-378 ms each with no degradation at
# all, and the seventeenth never returned. Averaged, that reads as "slow", and
# the thing blamed was the slowest visible step (unpacking the rootfs, 230 ms,
# constant to the end). The cause was somewhere else entirely.
#
# So this check reports EACH container's time on its own line, and asks the two
# questions a total cannot:
#
#   1. did every one of them actually reach running
#   2. with N running, how many host connections are still held
#
# (2) is the one that found it. A container is started with fork+exec, and
# without close-on-exec it inherits every socket the daemon had open at that
# moment -- the listening socket and other clients' connections -- and holds
# them for as long as it runs. The VMM's stream table filled at 32, which is
# two per container, which is sixteen containers.
#
#   MERE=<mere checkout> MENGD_SRC=<mengd> MRUN_SRC=<mrun> sh test/scale.sh [N]
#
# (2) IS ASKED OF THE VMM, NOT OF ITS LOG. The first version of this check
# subtracted two counts of log lines -- streams accepted minus streams released
# -- and got -6, which is not a number of anything: a release is logged for
# outward streams as well, and for a stream the guest never accepted, and
# neither of those has an "accepted" line. So the VMM answers STREAMS on its
# control socket with what its own table holds.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client as the oracle" >&2; exit 2; }
[ -n "${MENGD_SRC:-}" ] && [ -n "${MRUN_SRC:-}" ] || { echo "set MENGD_SRC and MRUN_SRC" >&2; exit 2; }
N="${1:-25}"
BURST="${BURST:-40}"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
M="scale$$"
export MVM_HOME="${MVM_HOME:-$HOME/.mvm}"
D="$MVM_HOME/$M"
out="$here/.build"; mkdir -p "$out"
# THE EVIDENCE OUTLIVES THE MACHINE. The first run of this check failed four
# times and then deleted the only log that could say why. Whatever it found,
# the logs are copied out before the machine goes.
# NAMED PER RUN. These are kept so a failure can be read afterwards, and a
# fixed name means the next run overwrites the evidence of the last one -- which
# is what happened: one failure in a row of five gates, and by the time it was
# looked at, a later run had replaced both logs.
cleanup() {
  [ -d "$D" ] && { cp "$D/vmm.log" "$out/scale-$M-vmm.log" 2>/dev/null
                   cp "$D/console.log" "$out/scale-$M-console.log" 2>/dev/null; }
  sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
  rm -rf "$D"; docker context rm "mvm-$M" >/dev/null 2>&1
  [ "$fail" = 0 ] || echo "  (the machine's logs are in $out/scale-$M-vmm.log and scale-$M-console.log)"
}
trap cleanup EXIT
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
# What the VMM's own stream table holds, right now. Two numbers and a total:
# "<in use> of <max>, <ever refused>".
streams() { printf 'STREAMS\n' | nc -U "$D/control.sock" 2>/dev/null | head -1; }
inuse()   { streams | awk '{print $2}'; }
refused() { streams | awk '{print $5}'; }

echo "== a machine =="
sh "$here/tools/mvm" start --name "$M" --disk-size 4096 > "$out/scale-start.log" 2>&1
say $? "mvm start"
grep -q "is up" "$out/scale-start.log"; say $? "it is up"
V="$D/vmm.log"
# The instrument, before the thing it measures. A control socket that does not
# answer STREAMS is an old VMM, and every count below would be empty -- which
# compares equal to nothing and passes.
[ -n "$(inuse)" ]; say $? "the VMM answers STREAMS ($(streams))"

export DOCKER_HOST="unix://$D/docker.sock"
export DOCKER_CONTEXT=
DOCKER_HOST= docker save alpine:latest -o "$out/scale-alpine.tar" 2>/dev/null
docker load -i "$out/scale-alpine.tar" >/dev/null 2>&1; say $? "an image loads"

# THE WITNESS, ASKED FIRST. A container can see its own descriptors, and the
# ones it did not open are the daemon's. This is the whole defect in one line,
# and it is cheaper than counting streams.
inh=$(docker run --rm alpine:latest sh -c 'ls /proc/self/fd' 2>/dev/null | tr -d '\r' | wc -l | tr -d ' ')
# 0, 1, 2 and the handle `ls` opened to read the directory: four.
[ "$inh" -le 4 ]; say $? "a container inherits no socket of the daemon's ($inh descriptors, 4 is its own)"

echo "== $N containers, one at a time =="
: > "$out/scale-times.txt"
i=0
while [ "$i" -lt "$N" ]; do
  a=$(ms)
  docker run -d --name s$i alpine:latest sh -c 'sleep 600' >/dev/null 2>"$out/scale-e.$i"
  b=$(ms)
  echo "$i $((b-a))" >> "$out/scale-times.txt"
  i=$((i + 1))
done
awk '{printf "%s ", $2} END {print ""}' "$out/scale-times.txt" | sed 's/^/  ms:  /'
r=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
[ "$r" = "$N" ]; say $? "all $N are running ($r)"
# THE SHAPE, NOT THE TOTAL. The last one must not cost several times the
# first: that is what a wall looks like from the inside when it is near.
f=$(head -1 "$out/scale-times.txt" | awk '{print $2}')
l=$(tail -1 "$out/scale-times.txt" | awk '{print $2}')
[ "$l" -lt $((f * 4)) ]; say $? "the last costs what the first did (${f} ms -> ${l} ms)"

echo "== what is held while they run =="
sleep 2
h=$(inuse)
[ "$h" = 0 ]; say $? "with $N running, the VMM holds 0 streams ($(streams))"
[ "$(refused)" = 0 ]; say $? "and it refused nothing"

echo "== $BURST at the same moment =="
for n in $(docker ps -aq 2>/dev/null); do docker rm -f "$n" >/dev/null 2>&1; done
rm -rf "$out/scale-burst"; mkdir -p "$out/scale-burst"
t0=$(ms)
i=0
while [ "$i" -lt "$BURST" ]; do
  docker run -d --name b$i alpine:latest sh -c 'sleep 600' >/dev/null 2>"$out/scale-burst/e.$i" &
  i=$((i + 1))
done
wait
t1=$(ms)
sleep 3
# A CLIENT THAT COULD NOT CONNECT IS NOT A SLOW CLIENT. When the stream table
# filled, the accept loop stopped, the backlog behind it filled, and the client
# was told the daemon was not running -- about the one machine that was.
bad=0
for e in "$out/scale-burst"/e.*; do [ -s "$e" ] && bad=$((bad + 1)); done
[ "$bad" = 0 ]; say $? "no client was refused a connection ($bad of $BURST)"
r=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
[ "$r" = "$BURST" ]; say $? "all $BURST are running ($r) in $((t1 - t0)) ms"
[ "$(inuse)" = 0 ]; say $? "and nothing is held afterwards ($(streams))"
[ "$(refused)" = 0 ]; say $? "and nothing was refused ($(streams))"

echo "== removing them takes their processes =="
for n in $(docker ps -aq 2>/dev/null); do docker rm -f "$n" >/dev/null 2>&1; done
left=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
# WHICH ones, not how many. A count cannot be acted on: two containers left out
# of forty is a different fact depending on whether they are the ones this
# check made, ones a --rm has not finished removing, or ones whose mount would
# not come off -- and the daemon says the last of those out loud.
[ "$left" = 0 ]
say $? "nothing left ($left$([ "$left" = 0 ] || echo ": $(docker ps -a --format '{{.Names}}/{{.Status}}' 2>/dev/null | tr '\n' ' ')"))"

# AND THE IMAGE IS STILL THERE. Every container's rootfs is an overlay whose
# lower is the image's one unpacked copy, so this is the check that it is still
# one. Removing the unmount and watching showed that overlayfs protects its own
# lower -- a delete through the merged view becomes a whiteout in the upper --
# so this passes even then, and what fails instead is the removal: a directory
# with a mount in it cannot be deleted at all. Both are asked, because the
# obvious guess about which one breaks was wrong.
o=$(docker run --rm alpine:latest echo image-survived 2>&1 | tr -d '\r\n')
[ "$o" = "image-survived" ]; say $? "and the image they shared is intact ($o)"
n=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c alpine)
[ "$n" = 1 ]; say $? "docker images still lists it ($n)"

[ "$fail" = 0 ] && echo "scale PASS" || echo "scale FAIL"
exit "$fail"
