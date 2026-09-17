#!/bin/sh
# test/lifecycle.sh — a machine somebody starts, stops, and starts again.
#
# Every other check here builds a machine, uses it, and throws it away. That
# hides the thing a person cares about most: **what survives**. A daemon whose
# store is on disk outlives its own process, and the part that does NOT survive
# is anything that was running -- while the store still says "running" about
# it, with a pid from a process table that no longer exists.
#
# So this one starts a machine the way a person would (tools/mvm), puts things
# in it, stops it, starts it again, and asks what is there.
#
# It also checks the stopping, because a machine that only half stops is worse
# than one that does not: the next start binds the same socket, fails, and the
# OLD guest answers it.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client as the oracle" >&2; exit 2; }
[ -n "${MENGD_SRC:-}" ] && [ -n "${MRUN_SRC:-}" ] || { echo "set MENGD_SRC and MRUN_SRC" >&2; exit 2; }
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
N="life$$"
# Under $HOME because the guest disk is built inside a container with this
# directory bind-mounted, and a container runtime shares $HOME and not much else.
export MVM_HOME="${MVM_HOME:-$HOME/.mvm}"
D="$MVM_HOME/$N"
mvm() { sh "$here/tools/mvm" "$@" --name "$N"; }
cleanup() { sh "$here/tools/mvm" stop --name "$N" >/dev/null 2>&1; rm -rf "$D"; docker context rm "mvm-$N" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== what a machine needs, before it is asked for =="
sh "$here/tools/mvm" doctor; say $? "doctor finds everything"

echo "== start =="
mvm start --disk-size 2048 > "$here/.build/life-start.log" 2>&1
say $? "mvm start"
grep -q "is up" "$here/.build/life-start.log"; say $? "it says so"
grep -q "overlay mounts" "$here/.build/life-start.log"; say $? "and what the guest can do (overlay)"
grep -q "bridge and veth" "$here/.build/life-start.log"; say $? "and networking"

export DOCKER_HOST="unix://$D/docker.sock"
export DOCKER_CONTEXT=
docker version --format '{{.Server.Version}}' >/dev/null 2>&1; say $? "a docker client reaches it"

DOCKER_HOST= docker save alpine:latest -o "$here/.build/life-alpine.tar" 2>/dev/null
docker load -i "$here/.build/life-alpine.tar" >/dev/null 2>&1; say $? "an image loads"
docker run -d --name survivor alpine:latest sh -c 'sleep 600' >/dev/null 2>&1
say $? "a container runs"
docker volume create keepsake >/dev/null 2>&1
docker run --rm -v keepsake:/v alpine:latest sh -c 'echo written-before-the-stop > /v/note' >/dev/null 2>&1
say $? "and writes into a volume"

echo "== stop =="
mvm stop > "$here/.build/life-stop.log" 2>&1; say $? "mvm stop"
sleep 1
docker version >/dev/null 2>&1; [ $? != 0 ]; say $? "the socket stops answering"
# The pid is gone, not merely forgotten: a VMM inside the framework's run()
# does not always go on the first signal.
[ ! -r "$D/vmm.pid" ]; say $? "and nothing is left holding the machine"

echo "== start again =="
mvm start > "$here/.build/life-start2.log" 2>&1; say $? "it starts a second time"
sleep 1
i=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c "^alpine:latest$")
[ "$i" = 1 ]; say $? "the image is still there ($i)"
c=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c "^survivor$")
[ "$c" = 1 ]; say $? "so is the container ($c)"

# WHAT MUST NOT SURVIVE. It was running when the machine stopped, and it is not
# running now -- but the store still said so, with a pid from a process table
# that no longer exists. docker ps would list it and docker stop would signal
# whatever owns that number now.
st=$(docker inspect -f '{{.State.Status}}' survivor 2>/dev/null)
[ "$st" = "exited" ]; say $? "and it is not pretending to still be running ($st)"
r=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^survivor$")
[ "$r" = 0 ]; say $? "docker ps does not list it ($r)"

o=$(docker run --rm -v keepsake:/v alpine:latest cat /v/note 2>/dev/null | tr -d '\r\n')
[ "$o" = "written-before-the-stop" ]; say $? "the volume kept what was written into it ($o)"
docker start survivor >/dev/null 2>&1
sleep 2
st=$(docker inspect -f '{{.State.Status}}' survivor 2>/dev/null)
[ "$st" = "running" ]; say $? "and the container can be started again ($st)"

echo "== stop, and leave nothing behind =="
mvm stop >/dev/null 2>&1; say $? "mvm stop"
sh "$here/tools/mvm" status --name "$N" 2>/dev/null | grep -q "is not running"
say $? "status says so"

[ "$fail" = 0 ] && echo "lifecycle PASS" || echo "lifecycle FAIL"
exit "$fail"
