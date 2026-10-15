"""Writes the Arrow test files used by `zig build test`.

Usage: python3 testdata/make.py   (needs pyarrow and polars; run from the project root)

Every file searches for "needle". The expected matches are listed in
src/search.zig ("search the test files"); change both together.
"""

import os

import pyarrow as pa
import pyarrow.feather as feather
import pyarrow.ipc as ipc

HERE = os.path.dirname(os.path.abspath(__file__))


def table():
    """Six rows, every kind of string array, non-string columns between them."""
    union = pa.UnionArray.from_dense(
        pa.array([0, 1, 0, 1, 0, 1], pa.int8()),
        pa.array([0, 0, 1, 1, 2, 2], pa.int32()),
        [pa.array([1, 2, 3]), pa.array(["needle", "u", "needle"])],
    )
    return pa.table(
        {
            "id": pa.array(range(6), pa.int64()),
            # Rows 0 and 4.
            "name": pa.array(["needle", None, "hay", "haystack", "a needle here", "x"]),
            # Row 4; with -i, 1 too. "nee" + "dle" (rows 2, 3) is no match.
            "note": pa.array(["", "NEEDLE", "nee", "dle", "needle\nline", None], pa.large_string()),
            "blob": pa.array([b"needle"] * 6, pa.binary()),  # not a string: not searched
            "u": union,  # strings inside unions are reported, not searched
            # Rows 1 (stored out of line) and 3 (inline: up to 12 bytes).
            "view": pa.array(["short", "a long string with needle inside", None, "needle", "", "n"], pa.string_view()),
            # Rows 0 and 3 (twice in row 3, reported once); "ne" + "edle" is no match.
            "tags": pa.array([["a", "needle"], None, [], ["needle", "needle2"], ["x"], ["ne", "edle"]]),
            # Rows 0 and 4. Row 1 is a null struct.
            "user": pa.array(
                [{"name": "needle", "age": 1}, None, {"name": "bob", "age": 3},
                 {"name": "x", "age": 4}, {"name": "needles", "age": 5}, {"name": "y", "age": 6}],
                pa.struct([("name", pa.string()), ("age", pa.int32())]),
            ),
            "f": pa.array([0.5] * 6),
            # Rows 1 and 4.
            "cat": pa.array(["red", "needle", "red", None, "needle", "blue"]).dictionary_encode(),
            # m[].value row 0, m[].key row 1.
            "m": pa.array(
                [[("k", "needle")], [("needle", "v")], [], None, [("a", "b")], [("c", "d")]],
                pa.map_(pa.string(), pa.string()),
            ),
            # Rows 1 and 5.
            "pair": pa.array(
                [["a", "b"], ["c", "needle"], ["e", "f"], ["g", "h"], ["i", "j"], ["needle", "k"]],
                pa.list_(pa.string(), 2),
            ),
        }
    )


def main():
    t = table()
    os.makedirs(os.path.join(HERE, "tree", "sub"), exist_ok=True)
    # Two record batches: rows 0-3 and 4-5.
    with ipc.new_file(os.path.join(HERE, "tree", "plain.arrow"), t.schema) as w:
        w.write_table(t, max_chunksize=4)
    feather.write_feather(t, os.path.join(HERE, "tree", "sub", "lz4.feather"), chunksize=4)  # LZ4 by default
    opts = ipc.IpcWriteOptions(compression="zstd")
    with ipc.new_file(os.path.join(HERE, "tree", "sub", "zstd.arrow"), t.schema, options=opts) as w:
        w.write_table(t, max_chunksize=4)

    # A stream with a dictionary delta, then a replacement: needle in rows 1, 4, 5 and 7.
    schema = pa.schema([("s", pa.dictionary(pa.int32(), pa.string()))])
    def batch(values, indices):
        arr = pa.DictionaryArray.from_arrays(pa.array(indices, pa.int32()), pa.array(values))
        return pa.record_batch([arr], schema=schema)
    opts = ipc.IpcWriteOptions(emit_dictionary_deltas=True)
    with ipc.new_stream(os.path.join(HERE, "tree", "deltas.arrows"), schema, options=opts) as w:
        w.write_batch(batch(["a", "needle"], [0, 1, 0]))
        w.write_batch(batch(["a", "needle", "b", "needle!"], [2, 3, 1]))
        w.write_batch(batch(["z", "needle-x"], [0, 1]))

    # polars has its own writer: string views everywhere, dictionaries of
    # string views with uint32 indices, and a file layout pyarrow never
    # writes (the region before the first block is not a valid stream, so
    # readers must use the footer). Needle in name 0 and 2 (2 is longer than
    # 12 bytes: not inline in its view), cat 1, tags[] 1 and st.inner 2.
    import polars as pl
    pl.DataFrame({
        "name": ["needle", None, "a long needle value past twelve bytes", "x"],
        "cat": pl.Series(["a", "needle", None, "a"], dtype=pl.Categorical),
        "tags": [["x"], ["needle", "z"], None, []],
        "st": [{"inner": "y"}, {"inner": "q"}, {"inner": "needle"}, None],
    }).write_ipc(os.path.join(HERE, "tree", "polars.arrow"))

    # Parquet: the same table (without the union, which Parquet can't
    # hold), written four ways; it matches as in the Arrow files. Plus a
    # file with no rows.
    import pyarrow.parquet as pq
    pt = t.drop_columns(["u"])
    pdir = os.path.join(HERE, "tree", "parquet")
    os.makedirs(pdir, exist_ok=True)
    # pyarrow's defaults: Snappy, dictionaries, v1 pages; two row groups.
    pq.write_table(pt, os.path.join(pdir, "snappy.parquet"), row_group_size=4)
    # v2 pages, DELTA_BYTE_ARRAY strings, zstd.
    strings = ["name", "note", "view", "user.name"]
    pq.write_table(pt, os.path.join(pdir, "v2_delta.parquet"), data_page_version="2.0", compression="zstd",
                   use_dictionary=False, column_encoding={c: "DELTA_BYTE_ARRAY" for c in strings})
    # PLAIN strings, gzip, a page for every few values.
    pq.write_table(pt, os.path.join(pdir, "plain_gzip.parquet"), compression="gzip", use_dictionary=False,
                   data_page_size=16, column_encoding={c: "PLAIN" for c in strings})
    # LZ4 (written as LZ4_RAW), DELTA_LENGTH_BYTE_ARRAY strings.
    pq.write_table(pt, os.path.join(pdir, "lz4.parquet"), compression="lz4", use_dictionary=False,
                   column_encoding={c: "DELTA_LENGTH_BYTE_ARRAY" for c in strings})
    pq.write_table(pt.slice(0, 0), os.path.join(pdir, "empty.parquet"))

    # Not Arrow files: skipped by extension, or reported as malformed.
    with open(os.path.join(HERE, "tree", "notes.txt"), "w") as f:
        f.write("needle\n")
    with open(os.path.join(HERE, "tree", "plain.arrow"), "rb") as f:
        data = f.read()
    with open(os.path.join(HERE, "tree", "truncated.arrow"), "wb") as f:
        f.write(data[: len(data) // 2])


if __name__ == "__main__":
    main()
