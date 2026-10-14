#!/bin/sh
# Benchmark fds on the log files from bench/make_logs.py, with hyperfine.
# Usage: bench/arrow.sh [dir]   (default: fixtures/logs; built if missing)
# Then compare with: python3 bench/others.py <dir>/logs.arrow
set -eu
cd "$(dirname "$0")/.."
DIR="${1:-fixtures/logs}"
if [ ! -f "$DIR/logs.arrow" ]; then
  mkdir -p "$DIR"
  python3 bench/make_logs.py "$DIR"
fi
zig build
FDS=zig-out/release/fds
F="$DIR/logs.arrow"
mkdir -p results
hyperfine -N --warmup 2 --runs 10 \
  --export-markdown results/arrow-logs.md --export-json results/arrow-logs.json \
  -n rare "$FDS $F host-4242.example" \
  -n none "$FDS $F zqxjv" \
  -n common "$FDS $F checkout" \
  -n ignore-case "$FDS -i $F HOST-4242.EXAMPLE" \
  -n regex "$FDS -E $F 'timeout [a-z]+ token'" \
  -n 'none -j1' "$FDS -j1 $F zqxjv" \
  -n 'none -j4' "$FDS -j4 $F zqxjv" \
  -n 'none lz4' "$FDS $DIR/logs_lz4.feather zqxjv"
