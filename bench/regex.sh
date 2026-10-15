#!/bin/sh
# Benchmark fds's regex engine (src/regex.zig) against PCRE2 (zig build
# -Dpcre2) on the log files from bench/make_logs.py, with hyperfine.
# Usage: bench/regex.sh [dir]   (default: fixtures/logs; built if missing)
set -eu
cd "$(dirname "$0")/.."
DIR="${1:-fixtures/logs}"
if [ ! -f "$DIR/logs.arrow" ]; then
  mkdir -p "$DIR"
  python3 bench/make_logs.py "$DIR"
fi
zig build
zig build -Dpcre2 -p zig-out/pcre2
FDS=zig-out/release/fds
PCRE2=zig-out/pcre2/release/fds
mkdir -p results
for f in arrow parquet; do
  F="$DIR/logs.$f"
  set --
  while IFS='	' read -r flags re; do
    set -- "$@" -n "fds $flags '$re'" "$FDS $flags $F '$re'" \
      -n "pcre2 $flags '$re'" "$PCRE2 $flags $F '$re'"
  done <<'PATTERNS'
-E	timeout [a-z]+ token
-w	checkout
-E	\d{5}$
-E	[xz]{3}
-E	error|fatal
-E -i	TIMEOUT \w+ TOKEN
-E	^/api/v[0-9]+/checkout/\d+$
-E	(fast|slow) (queue|cache)
PATTERNS
  # -i: a search with no match exits 1, as grep does.
  hyperfine -N -i --warmup 2 --runs 10 \
    --export-markdown "results/regex-$f.md" --export-json "results/regex-$f.json" "$@"
done
