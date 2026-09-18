#!/bin/sh
# tools/checkopts.sh -- does what a tool accepts appear in what it says?
#
# An option that is merely undocumented breaks no test: it works perfectly for
# everyone who already knows it exists. That is how `mvm --help` came to be
# missing two commands -- the help was a comment block extracted by LINE NUMBER
# (`sed -n '3,14p'`), so documenting one new option pushed `mvm status` and
# `mvm doctor` off the end of it, and the tool went on accepting both.
#
# Two questions, because they fail differently:
#
#   1. EVERY SCRIPT: does each option its argument parser answers to appear in
#      that script's own header comment? Read as text -- nothing is run, which
#      matters, because "invoke it with a bogus flag and read the complaint" is
#      only safe for a tool that answers a bogus flag with its usage.
#
#   2. tools/mvm ONLY: does what usage() actually PRINTS name every option and
#      every subcommand? This is the one that catches the truncation; checking
#      the comment alone would have passed while the help was missing two
#      commands.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# The head of the file, up to the first line that is not a comment.
header() { awk '/^#!/ { next } /^#/ { print; next } { exit }' "$1"; }

# What an argument parser answers to: `--name)` or `-p|--publish)` at the head
# of a case arm. Not every script has one, and that is not a failure.
opts_of() {
  sed -n 's/^[[:space:]]*\(-[^)]*\))[[:space:]]*.*/\1/p' "$1" \
    | tr '|' '\n' | sed 's/[[:space:]]//g' | grep '^-' | sort -u
}

echo "== every option is in its own script's header =="
for f in "$here/tools/mvm" "$here"/tools/*.sh; do
  [ -r "$f" ] || continue
  case "$f" in *checkopts.sh) continue;; esac
  h=$(header "$f")
  o=$(opts_of "$f")
  if [ -z "$o" ]; then
    echo "  --    $(basename "$f") takes no options"
    continue
  fi
  n=0; bad=0
  for x in $o; do
    n=$((n + 1))
    case "$h" in *"$x"*) ;; *) echo "  FAIL  $(basename "$f") accepts $x and its header does not say so"; bad=1; fail=1;; esac
  done
  [ "$bad" = 0 ] && echo "  ok    $(basename "$f") names all $n"
done

echo "== and mvm's help PRINTS them, which is a different question =="
T="${1:-$here/tools/mvm}"
help=$(sh "$T" --this-is-not-a-command 2>&1 || true)
if [ -z "$help" ]; then
  echo "  FAIL  it printed no usage at all"; fail=1
else
  n=0
  for x in $(opts_of "$T"); do
    n=$((n + 1))
    case "$help" in *"$x"*) ;; *) echo "  FAIL  accepts $x, the printed help does not name it"; fail=1;; esac
  done
  for c in $(sed -n '/^case "\$cmd" in/,/^esac/p' "$T" \
             | sed -n 's/^[[:space:]]*\([a-z][a-z-]*\))[[:space:]]*.*/\1/p' | sort -u); do
    n=$((n + 1))
    case "$help" in *"mvm $c"*) ;; *) echo "  FAIL  accepts \`mvm $c', the printed help does not name it"; fail=1;; esac
  done
  # A parser that stopped matching would find nothing and pass by asking
  # nothing. mvm has options and subcommands; zero means the extraction broke.
  [ "$n" -gt 0 ] || { echo "  FAIL  found no options or commands at all -- the extraction is broken"; fail=1; }
  [ "$fail" = 0 ] && echo "  ok    the printed help names all $n"
fi
exit $fail
