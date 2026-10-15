"""Runs the examples in docs/*.md and README.md, and writes their output.

Usage: python3 docs/examples.py [--check]   (after `zig build` and
`zig build -Dpcre2 -p zig-out/pcre2`)

In each ```console block, every `$ command` line is run with `sh` in
testdata/tree, with zig-out/release on PATH (zig-out/pcre2/release for
a block right after a `<!-- examples: pcre2 -->` line), and the lines
after it are replaced with
what it prints, stderr first. Run it after changing the output or the
test files, and review the diff.

With --check, nothing is written: it fails if any example's output
differs from what the page shows. Lines are compared as sets, since files
in a directory come out in no fixed order, and with runs of spaces
collapsed, since other tools pad differently (`uniq -c` on macOS).
"""

import difflib
import glob
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
BLOCK = re.compile(r"(<!-- examples: (\w+) -->\n)?```console\n(.*?)```", re.S)


def run(cmd, kind):
    if not os.path.exists(os.path.join(BINS[kind], "fds")):
        sys.exit(f"no fds in {BINS[kind]}: build it first (see the usage)")
    env = dict(os.environ, PATH=BINS[kind] + os.pathsep + os.environ["PATH"], NO_COLOR="1")
    p = subprocess.run(["sh", "-c", cmd], cwd=TREE, env=env, capture_output=True, text=True)
    return (p.stderr + p.stdout).rstrip("\n").splitlines()


def examples(body):
    """The block's commands, each with the output lines shown after it."""
    out = []
    for line in body.splitlines():
        if line.startswith("$ "):
            out.append((line[2:], []))
        elif out:
            out[-1][1].append(line)
    return out


def normal(lines):
    return sorted(" ".join(line.split()) for line in lines)


def main():
    check = "--check" in sys.argv[1:]
    pages = [os.path.join(ROOT, "README.md")] + sorted(glob.glob(os.path.join(ROOT, "docs", "*.md")))
    failed = 0
    for path in pages:
        name = os.path.relpath(path, ROOT)
        text = open(path).read()

        def fill(m):
            nonlocal failed
            marker, kind = m.group(1) or "", m.group(2) or ""
            lines = []
            for cmd, shown in examples(m.group(3)):
                got = run(cmd, kind)
                if check and normal(got) != normal(shown):
                    failed += 1
                    print(f"{name}: $ {cmd}")
                    sys.stdout.writelines(difflib.unified_diff(
                        [s + "\n" for s in shown], [g + "\n" for g in got], "shown", "printed now"))
                lines.append("$ " + cmd)
                lines.extend(got)
            return marker + "```console\n" + "\n".join(lines) + "\n```"

        new = BLOCK.sub(fill, text)
        if not check and new != text:
            open(path, "w").write(new)
            print(f"{name}: updated")
    if check:
        if failed:
            sys.exit(f"{failed} example(s) out of date: run python3 docs/examples.py")
        print("every example's output is up to date")


if __name__ == "__main__":
    main()
