"""Corrupts Arrow files at random and checks that fds survives them.

Usage: python3 testdata/mutate.py <fds binary> [runs] [seed] [file...]
(default files: testdata/tree)

Use the debug build: there an out-of-bounds access panics instead of
silently reading garbage. Each run flips, overwrites or replaces a few
bytes of a file and searches it. fds must exit 0 (a malformed file is
reported on stderr, not a crash), within 10 seconds and 1 GB of memory.
"""

import glob
import os
import random
import resource
import subprocess
import sys
import tempfile

LIMIT_SECONDS = 10
LIMIT_BYTES = 1 << 30


def limit_memory():
    # A runaway allocation then fails fast instead of swapping. Address
    # space, not memory: mapping the file and thread stacks count too.
    # Not every system allows lowering it (macOS may not); the peak
    # memory check below still applies.
    try:
        resource.setrlimit(resource.RLIMIT_AS, (LIMIT_BYTES * 4, LIMIT_BYTES * 4))
    except (ValueError, OSError):
        pass


def peak_bytes():
    """Peak memory of the largest child so far (ru_maxrss is KB on Linux, bytes on macOS)."""
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return peak if sys.platform == "darwin" else peak * 1024


def main():
    fds = sys.argv[1]
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    r = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    sources = sys.argv[4:] or sorted(
        p for p in glob.glob("testdata/tree/**/*", recursive=True)
        if p.endswith((".arrow", ".feather", ".arrows")) and "truncated" not in p)
    tmp = tempfile.mkdtemp()
    failures = 0
    for i in range(runs):
        src = r.choice(sources)
        data = bytearray(open(src, "rb").read())
        for _ in range(r.randint(1, 8)):
            k = r.randrange(len(data))
            mode = r.random()
            if mode < 0.6:
                data[k] = r.randrange(256)
            elif mode < 0.8:
                data[k] ^= 1 << r.randrange(8)
            else:  # extreme values for lengths and offsets
                data[k:k + 4] = r.choice([b"\xff\xff\xff\x7f", b"\x00\x00\x00\x80", b"\xff\xff\xff\xff", b"\x00\x00\x00\x00"])
        path = os.path.join(tmp, f"m{i}" + os.path.splitext(src)[1])
        with open(path, "wb") as f:
            f.write(data)
        try:
            res = subprocess.run([fds, "-E", path, "n[a-z]+e"], capture_output=True,
                                 timeout=LIMIT_SECONDS, preexec_fn=limit_memory)
            peak = peak_bytes()
            problem = None
            if res.returncode != 0:
                problem = f"exit {res.returncode}: {res.stderr.decode()[-500:]}"
            elif peak > LIMIT_BYTES:
                problem = f"used {peak >> 20} MB"
        except subprocess.TimeoutExpired:
            problem = f"still running after {LIMIT_SECONDS} s"
        if problem:
            failures += 1
            print(f"FAIL {path} (from {src}): {problem}")
            if failures >= 5:
                break
        else:
            os.remove(path)
    print(f"{i + 1} corrupted files, {failures} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
