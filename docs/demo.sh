#!/bin/sh
# Records docs/demo.gif from docs/demo.tape, on the benchmark files (made by
# bench/make_logs.py if missing). Needs vhs, which needs ttyd and ffmpeg.
set -eu
cd "$(dirname "$0")/.."
DIR=fixtures/logs
if [ ! -f "$DIR/logs.arrow" ]; then
  mkdir -p "$DIR"
  python3 bench/make_logs.py "$DIR"
fi
zig build
# 10,000 terms for the -f scene: random strings, and a few host names that occur.
python3 - "$DIR/terms.txt" <<'PY'
import random, sys
r = random.Random(5)
with open(sys.argv[1], "w") as f:
    for i in range(10000):
        if i % 100 == 0:
            f.write(f"host-{r.randint(0, 9999)}.example\n")
        else:
            f.write("".join(r.choice("abcdefghijklmnopqrstuvwxyz0123456789-") for _ in range(r.randint(8, 24))) + "\n")
PY
vhs docs/demo.tape
