"""Compares fds with a Python search on existing Arrow files.

Usage: python3 testdata/check.py <fds binary> <path> <term> [-i]   (needs pyarrow)

Reads every .arrow, .feather and .arrows file under <path> (or <path>
itself) with pyarrow, finds the values containing <term> with the same
reference search as fuzz.py, and checks that `fds` prints exactly those
matches. Files pyarrow can't read must be reported by fds, not searched.
"""

import os
import subprocess
import sys

import pyarrow as pa
import pyarrow.ipc as ipc

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import ascii_lower, hits  # noqa: E402

EXTENSIONS = (".arrow", ".feather", ".arrows")


def arrow_files(root):
    if os.path.isfile(root):
        yield root
        return
    for d, _, names in os.walk(root):
        for n in sorted(names):
            if n.lower().endswith(EXTENSIONS):
                yield os.path.join(d, n)


def read(path):
    """The table in an IPC file or stream; the format comes from the magic."""
    source = pa.memory_map(path)
    if source.read(6) == b"ARROW1":
        return ipc.open_file(path).read_all()
    return ipc.open_stream(path).read_all()


def expected_matches(root, term, fold):
    expected, bad, rows_total = set(), [], 0
    for path in arrow_files(root):
        try:
            table = read(path)
        except Exception as e:  # noqa: BLE001
            bad.append((path, str(e).splitlines()[0]))
            continue
        rows_total += table.num_rows
        needle = ascii_lower(term) if fold else term
        # Paths as fds prints them: "<root>/<relative path>", or the root.
        shown = path if os.path.isfile(root) else root.rstrip("/") + "/" + os.path.relpath(path, root)
        for row_index, row in enumerate(table.to_pylist()):
            for f in table.schema:
                for col in hits(f.name, f.type, row[f.name], needle, fold):
                    expected.add(f"{shown}:{col}:{row_index}")
    return expected, bad, rows_total


def main():
    fds, root, term = sys.argv[1:4]
    fold = "-i" in sys.argv[4:]
    expected, bad, rows = expected_matches(root, term, fold)
    out = subprocess.run([fds] + (["-i"] if fold else []) + [root, term], capture_output=True, text=True)
    got = set(out.stdout.splitlines())
    reported = out.stderr.splitlines()
    ok = got == expected
    for path, why in bad:
        if not any(line.startswith(f"fds: {path}") or path in line for line in reported):
            print(f"not reported by fds: {path} ({why})")
            ok = False
    bad_paths = {path for path, _ in bad}
    for line in reported:
        if not any(p in line for p in bad_paths):
            print(f"fds reported a file pyarrow reads: {line}")
            ok = False
    print(f"{len(list(arrow_files(root)))} files, {rows} rows, {len(expected)} matches, "
          f"{len(bad)} unreadable: " + ("fds agrees" if ok else "MISMATCH"))
    if not ok:
        print("missing:", sorted(expected - got)[:10])
        print("extra:", sorted(got - expected)[:10])
        print("stderr:", out.stderr[:2000])
        sys.exit(1)


if __name__ == "__main__":
    main()
