#!/bin/sh
# Benchmark many terms at once (-f: the Aho-Corasick search, src/multi.zig)
# on the log files from bench/make_logs.py, with hyperfine.
# Usage: bench/terms.sh [dir]   (default: fixtures/logs; built if missing)
# Each term file holds random strings of 8 to 24 bytes, one in a hundred
# being a host name that occurs in the data.
set -eu
cd "$(dirname "$0")/.."
DIR="${1:-fixtures/logs}"
if [ ! -f "$DIR/logs.arrow" ]; then
  mkdir -p "$DIR"
  python3 bench/make_logs.py "$DIR"
fi
zig build
FDS=zig-out/release/fds
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 - "$T" <<'PY'
import random, sys
r = random.Random(5)
for n in [8, 100, 1000, 10000, 100000]:
    with open(f"{sys.argv[1]}/{n}.txt", "w") as f:
        for i in range(n):
            if i % 100 == 0:
                f.write(f"host-{r.randint(0, 9999)}.example\n")
            else:
                f.write("".join(r.choice("abcdefghijklmnopqrstuvwxyz0123456789-") for _ in range(r.randint(8, 24))) + "\n")
PY
mkdir -p results
for f in arrow parquet; do
  set --
  for n in 8 100 1000 10000 100000; do
    set -- "$@" -n "$n terms" "$FDS --count -f $T/$n.txt $DIR/logs.$f"
  done
  hyperfine -N -i --warmup 1 --runs 5 \
    --export-markdown "results/terms-$f.md" --export-json "results/terms-$f.json" "$@"
done
