"""Writes the Arrow test files used by `zig build test`.

Usage: python3 testdata/make.py   (needs pyarrow; run from the project root)

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
            "u": union,  # strings inside unions are not searched
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

    # Not Arrow files: skipped by extension, or reported as malformed.
    with open(os.path.join(HERE, "tree", "notes.txt"), "w") as f:
        f.write("needle\n")
    with open(os.path.join(HERE, "tree", "plain.arrow"), "rb") as f:
        data = f.read()
    with open(os.path.join(HERE, "tree", "truncated.arrow"), "wb") as f:
        f.write(data[: len(data) // 2])


if __name__ == "__main__":
    main()
