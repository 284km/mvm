#!/bin/sh
# tools/checkopts.sh -- does the tool's help name everything the tool accepts?
#
# `mvm --help` is a block of comment at the top of tools/mvm, and it used to be
# extracted by LINE NUMBER: `sed -n '3,14p'`. Adding one line to that block --
# the line documenting a new option -- pushed `mvm status` and `mvm doctor` off
# the end of it. The tool went on accepting both and stopped saying so, and
# nothing anywhere noticed, because an option that is merely undocumented
# breaks no test: it works perfectly for everyone who already knows it exists.
#
# This asks the two halves to agree. It needs nothing installed and takes no
# time, so it can run on every push.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
T="${1:-$here/tools/mvm}"
[ -r "$T" ] || { echo "checkopts: no such file: $T" >&2; exit 2; }
fail=0

help=$(sh "$T" --this-is-not-a-command 2>&1 || true)
[ -n "$help" ] || { echo "checkopts: the tool printed no usage at all" >&2; exit 1; }

# What the argument parser answers to: `--name)` and `-p)` at the head of a
# case arm. The `|` form is split so `--foo|--bar)` counts as both.
opts=$(sed -n 's/^[[:space:]]*\(-[^)]*\))[[:space:]]*.*/\1/p' "$T" | tr '|' '\n' \
       | sed 's/[[:space:]]//g' | grep '^-' | sort -u)
# And the subcommands it dispatches on.
cmds=$(sed -n '/^case "\$cmd" in/,/^esac/p' "$T" \
       | sed -n 's/^[[:space:]]*\([a-z][a-z-]*\))[[:space:]]*.*/\1/p' | sort -u)

n=0
for o in $opts; do
  n=$((n + 1))
  case "$help" in *"$o"*) ;; *) echo "  not in the usage: $o"; fail=1;; esac
done
for c in $cmds; do
  n=$((n + 1))
  case "$help" in *"mvm $c"*) ;; *) echo "  not in the usage: mvm $c"; fail=1;; esac
done
# Nothing found means the patterns above stopped matching, which would make
# this pass by asking nothing.
[ "$n" -gt 5 ] || { echo "checkopts: only found $n options and commands -- the extraction is broken" >&2; exit 1; }

[ "$fail" = 0 ] && echo "checkopts: the usage names all $n options and commands"
exit $fail
