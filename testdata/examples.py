"""Rewrites the output in the examples of EXAMPLES.md and README.md.

Usage: python3 testdata/examples.py   (from the project root, after
`zig build` and `zig build -Dpcre2 -p zig-out/pcre2`)

In each ```console block, every `$ command` line is run with `sh` in
testdata/tree, with zig-out/release on PATH (zig-out/pcre2/release for
blocks marked ```console pcre2), and the lines after it are replaced with
what it prints, stderr first. Run it after changing the output format or
the test files, and review the diff.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TREE = os.path.join(ROOT, "testdata", "tree")
BINS = {
    "": os.path.join(ROOT, "zig-out", "release"),
    "pcre2": os.path.join(ROOT, "zig-out", "pcre2", "release"),
}


def run(cmd, kind):
    if not os.path.exists(os.path.join(BINS[kind], "fds")):
        sys.exit(f"no fds in {BINS[kind]}: build it first (see the usage)")
    env = dict(os.environ, PATH=BINS[kind] + os.pathsep + os.environ["PATH"], NO_COLOR="1")
    p = subprocess.run(["sh", "-c", cmd], cwd=TREE, env=env, capture_output=True, text=True)
    return p.stderr + p.stdout


def fill(m):
    info, body = m.group(1), m.group(2)
    lines = []
    for line in body.splitlines():
        if line.startswith("$ "):
            lines.append(line)
            lines.extend(run(line[2:], info.strip()).rstrip("\n").splitlines())
    return "```console" + info + "\n" + "\n".join(lines) + "\n```"


for name in ["EXAMPLES.md", "README.md"]:
    path = os.path.join(ROOT, name)
    text = open(path).read()
    new = re.sub(r"```console([^\n]*)\n(.*?)```", fill, text, flags=re.S)
    if new != text:
        open(path, "w").write(new)
        print(f"{name}: updated")
    else:
        print(f"{name}: unchanged")
