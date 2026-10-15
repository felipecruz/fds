#!/bin/sh
# Benchmark fds on the Parquet log files from bench/make_logs.py, with hyperfine.
# Usage: bench/parquet.sh [dir]   (default: fixtures/logs; built if missing)
# Then compare with: python3 bench/others.py <dir>
set -eu
cd "$(dirname "$0")/.."
DIR="${1:-fixtures/logs}"
if [ ! -f "$DIR/logs.parquet" ]; then
  mkdir -p "$DIR"
  python3 bench/make_logs.py "$DIR"
fi
zig build
FDS=zig-out/release/fds
mkdir -p results
# -i: a search with no match exits 1, as grep does.
hyperfine -N -i --warmup 2 --runs 10 \
  --export-markdown results/parquet-logs.md --export-json results/parquet-logs.json \
  -n 'snappy rare' "$FDS $DIR/logs.parquet host-4242.example" \
  -n 'snappy none' "$FDS $DIR/logs.parquet zqxjv" \
  -n 'snappy common' "$FDS $DIR/logs.parquet checkout" \
  -n 'snappy regex' "$FDS -E $DIR/logs.parquet 'timeout [a-z]+ token'" \
  -n 'plain none' "$FDS $DIR/logs_plain.parquet zqxjv" \
  -n 'zstd none' "$FDS $DIR/logs_zstd.parquet zqxjv"
