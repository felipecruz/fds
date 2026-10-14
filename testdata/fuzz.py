"""Differential test: fds against a pure-Python search, on random tables.

Usage: python3 testdata/fuzz.py <fds binary> [iterations] [seed]   (needs pyarrow)

Each iteration writes a random table (random string types, nesting, nulls,
dictionary encoding, batch sizes, compression, file or stream format) and
compares `fds` output with what Python finds by walking `to_pylist()`.
"""

import os
import random
import subprocess
import sys
import tempfile

import pyarrow as pa
import pyarrow.ipc as ipc

ALPHABET = "abAB\n"


def rand_str(r):
    return "".join(r.choice(ALPHABET) for _ in range(r.randint(0, 6)))


def rand_type(r, depth=0):
    leaves = [pa.string(), pa.large_string(), pa.string_view(), "dict", pa.int32(), pa.binary()]
    if depth < 2 and r.random() < 0.4:
        kind = r.choice(["struct", "list", "large_list", "fixed", "map"])
        if kind == "struct":
            return pa.struct([(f"f{i}", rand_type(r, depth + 1)) for i in range(r.randint(1, 3))])
        if kind == "list":
            return pa.list_(rand_type(r, depth + 1))
        if kind == "large_list":
            return pa.large_list(rand_type(r, depth + 1))
        if kind == "fixed":
            return pa.list_(rand_type(r, depth + 1), r.randint(1, 3))
        return pa.map_(pa.string(), rand_type(r, depth + 1))
    t = r.choice(leaves)
    if t == "dict":
        return pa.dictionary(r.choice([pa.int8(), pa.int16(), pa.int32(), pa.uint32(), pa.int64()]), pa.string())
    return t


def rand_value(r, t):
    if r.random() < 0.15:
        return None
    if pa.types.is_struct(t):
        return {f.name: rand_value(r, f.type) for f in t}
    if pa.types.is_fixed_size_list(t):
        return [rand_value(r, t.value_type) for _ in range(t.list_size)]
    if pa.types.is_map(t):
        return [(rand_str(r), rand_value(r, t.item_type)) for _ in range(r.randint(0, 3))]
    if pa.types.is_list(t) or pa.types.is_large_list(t):
        return [rand_value(r, t.value_type) for _ in range(r.randint(0, 3))]
    if pa.types.is_integer(t):
        return r.randint(0, 9)
    if pa.types.is_binary(t):
        return rand_str(r).encode()
    return rand_str(r)


def is_string(t):
    return pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t) or (
        pa.types.is_dictionary(t) and pa.types.is_string(t.value_type))


def hits(name, t, v, term, fold):
    """Column paths under `name` whose strings in value `v` contain term."""
    if v is None:
        return set()
    if is_string(t):
        found = term.lower() in v.lower() if fold else term in v
        return {name} if found else set()
    out = set()
    if pa.types.is_struct(t):
        for f in t:
            out |= hits(f"{name}.{f.name}", f.type, v[f.name], term, fold)
    elif pa.types.is_map(t):
        for k, item in v:
            out |= hits(f"{name}[].key", pa.string(), k, term, fold)
            out |= hits(f"{name}[].value", t.item_type, item, term, fold)
    elif pa.types.is_list(t) or pa.types.is_large_list(t) or pa.types.is_fixed_size_list(t):
        for item in v:
            out |= hits(f"{name}[]", t.value_type, item, term, fold)
    return out


def ascii_lower(s):
    return "".join(c.lower() if "A" <= c <= "Z" else c for c in s)


def main():
    fds = sys.argv[1]
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    r = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    tmp = tempfile.mkdtemp()
    total = 0
    for it in range(iterations):
        types = [rand_type(r) for _ in range(r.randint(1, 5))]
        n = r.randint(0, 40)
        cols = {}
        for i, t in enumerate(types):
            values = [rand_value(r, t) for _ in range(n)]
            if pa.types.is_dictionary(t):
                cols[f"c{i}"] = pa.array(values, pa.string()).dictionary_encode().cast(t)
            else:
                cols[f"c{i}"] = pa.array(values, t)
        table = pa.table(cols)
        if n > 2 and r.random() < 0.3:  # a slice: offsets that don't start at 0
            start = r.randint(1, n - 1)
            table = table.slice(start)
        compression = r.choice([None, "lz4", "zstd"])
        stream = r.random() < 0.3
        path = os.path.join(tmp, f"t{it}." + ("arrows" if stream else "arrow"))
        opts = ipc.IpcWriteOptions(compression=compression)
        chunk = r.randint(1, 10)
        writer = ipc.new_stream if stream else ipc.new_file
        with writer(path, table.schema, options=opts) as w:
            w.write_table(table, max_chunksize=chunk)

        term = "".join(r.choice("abAB") for _ in range(r.randint(1, 3)))
        fold = r.random() < 0.3
        expected = set()
        rows = table.to_pylist()
        for row_index, row in enumerate(rows):
            for f in table.schema:
                for col in hits(f.name, f.type, row[f.name], ascii_lower(term) if fold else term, fold):
                    expected.add(f"{path}:{col}:{row_index}")
        args = [fds] + (["-i"] if fold else []) + [path, term]
        out = subprocess.run(args, capture_output=True, text=True)
        got = set(out.stdout.splitlines())
        total += len(expected)
        if out.returncode != 0 or out.stderr or got != expected:
            print(f"MISMATCH iteration {it}: {' '.join(args)} (chunk {chunk}, {compression})")
            print("schema:", table.schema)
            print("stderr:", out.stderr)
            print("missing:", sorted(expected - got)[:10])
            print("extra:", sorted(got - expected)[:10])
            sys.exit(1)
    print(f"{iterations} random tables, {total} matches: fds agrees with Python")


if __name__ == "__main__":
    main()
