"""Differential test: fds against a pure-Python search, on random tables.

Usage: python3 testdata/fuzz.py <fds binary> [iterations] [seed] [--parquet]
(needs pyarrow)

Each iteration writes a random table (random string types, nesting, nulls,
dictionary encoding, batch sizes, compression) as an Arrow file or stream,
or with --parquet as a Parquet file (random codec, dictionary on or off,
page version, string encoding, page and row group sizes), and compares
`fds` output with what Python finds by walking `to_pylist()`.
"""

import os
import random
import subprocess
import sys
import tempfile

import pyarrow as pa
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

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
    """A string array to search: string, large_string, string_view, or a
    dictionary whose values are one of those."""
    if pa.types.is_dictionary(t):
        t = t.value_type
    return pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t)


def hits(name, t, v, term, fold, lists=True):
    """Column paths under `name` whose strings in value `v` contain term.
    With lists=False, strings inside lists and maps don't count (fds does
    not search them in Parquet files yet)."""
    if v is None:
        return set()
    if is_string(t):
        found = term.lower() in v.lower() if fold else term in v
        return {name} if found else set()
    out = set()
    if pa.types.is_struct(t):
        for f in t:
            out |= hits(f"{name}.{f.name}", f.type, v[f.name], term, fold, lists)
    elif not lists:
        pass
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


def without_views(t):
    """`t` with every string view, at any depth, replaced by a string."""
    if pa.types.is_string_view(t):
        return pa.string()
    if pa.types.is_struct(t):
        return pa.struct([(f.name, without_views(f.type)) for f in t])
    if pa.types.is_map(t):
        return pa.map_(t.key_type, without_views(t.item_type))
    if pa.types.is_fixed_size_list(t):
        return pa.list_(without_views(t.value_type), t.list_size)
    if pa.types.is_large_list(t):
        return pa.large_list(without_views(t.value_type))
    if pa.types.is_list(t):
        return pa.list_(without_views(t.value_type))
    return t


def write_parquet(r, table, path):
    """Writes `table` with random Parquet settings; returns them."""
    opts = {
        "compression": r.choice(["none", "snappy", "gzip", "zstd", "lz4"]),
        "use_dictionary": r.random() < 0.6,
        "data_page_version": r.choice(["1.0", "2.0"]),
        "data_page_size": r.choice([64, 1024, 1 << 20]),  # small: many pages
        "row_group_size": r.randint(1, 50),
        "write_statistics": r.random() < 0.5,
    }
    if not opts["use_dictionary"] and r.random() < 0.6:
        strings = [f.name for f in table.schema if pa.types.is_string(f.type) or pa.types.is_large_string(f.type)]
        if strings:
            enc = r.choice(["PLAIN", "DELTA_LENGTH_BYTE_ARRAY", "DELTA_BYTE_ARRAY"])
            opts["column_encoding"] = {c: enc for c in strings}
    pq.write_table(table, path, **opts)
    return opts


def main():
    fds = sys.argv[1]
    use_parquet = "--parquet" in sys.argv
    rest = [a for a in sys.argv[2:] if a != "--parquet"]
    iterations = int(rest[0]) if len(rest) > 0 else 200
    r = random.Random(int(rest[1]) if len(rest) > 1 else 1)
    tmp = tempfile.mkdtemp()
    total = 0
    skipped = 0
    for it in range(iterations):
        types = [rand_type(r) for _ in range(r.randint(1, 5))]
        if use_parquet:  # Parquet has no string views; they are written as strings
            types = [without_views(t) for t in types]
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
        if use_parquet:
            path = os.path.join(tmp, f"t{it}.parquet")
            try:
                settings = write_parquet(r, table, path)
                table = pq.read_table(path)  # what the file holds
            except pa.ArrowException:
                # pyarrow fails to write some nested tables in tiny row
                # groups, or to read them back: nothing to compare.
                skipped += 1
                continue
        else:
            compression = r.choice([None, "lz4", "zstd"])
            stream = r.random() < 0.3
            path = os.path.join(tmp, f"t{it}." + ("arrows" if stream else "arrow"))
            opts = ipc.IpcWriteOptions(compression=compression)
            chunk = r.randint(1, 10)
            writer = ipc.new_stream if stream else ipc.new_file
            with writer(path, table.schema, options=opts) as w:
                w.write_table(table, max_chunksize=chunk)
            settings = f"chunk {chunk}, {compression}"

        term = "".join(r.choice("abAB") for _ in range(r.randint(1, 3)))
        fold = r.random() < 0.3
        expected = set()
        rows = table.to_pylist()
        for row_index, row in enumerate(rows):
            for f in table.schema:
                for col in hits(f.name, f.type, row[f.name], ascii_lower(term) if fold else term, fold, lists=not use_parquet):
                    expected.add(f"{path}:{col}:{row_index}")
        args = [fds] + (["-i"] if fold else []) + [path, term]
        out = subprocess.run(args, capture_output=True, text=True)
        got = set(out.stdout.splitlines())
        total += len(expected)
        if out.returncode != 0 or out.stderr or got != expected:
            print(f"MISMATCH iteration {it}: {' '.join(args)} ({settings})")
            print("schema:", table.schema)
            print("stderr:", out.stderr)
            print("missing:", sorted(expected - got)[:10])
            print("extra:", sorted(got - expected)[:10])
            sys.exit(1)
    unreadable = f" ({skipped} that pyarrow couldn't write or read back skipped)" if skipped else ""
    print(f"{iterations} random tables, {total} matches: fds agrees with Python{unreadable}")


if __name__ == "__main__":
    main()
