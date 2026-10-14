"""Writes the benchmark files: 20M rows of log-like data, 2.3 GB of strings.

Usage: python3 bench/make_logs.py <out dir>   (needs pyarrow and numpy)
Writes logs.arrow (uncompressed, 20 record batches), logs_lz4.feather, and
the same table as Parquet: logs.parquet (pyarrow's defaults: Snappy,
dictionaries), logs_zstd.parquet and logs_plain.parquet (no dictionaries).
Columns: ts (int64), host, path, level (dictionary), message (8 words).
"""

import os
import sys

import numpy as np
import pyarrow as pa
import pyarrow.feather as feather
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

out = sys.argv[1]
rng = np.random.default_rng(42)
words = np.array((
    "error warning info debug request response timeout user session token cache miss hit "
    "database query slow fast retry connect disconnect upload download payment order cart checkout "
    "login logout admin service worker queue job failed succeeded started stopped").split())
levels = pa.array(words[:4])
batches = []
for _ in range(20):
    n = 1_000_000
    msg = pa.array([" ".join(r) for r in words[rng.integers(0, len(words), size=(n, 8))]])
    host = pa.array([f"host-{i:04d}.example.com" for i in rng.integers(0, 5000, n)])
    path = pa.array([f"/api/v1/{a}/{b}" for a, b in zip(words[rng.integers(0, len(words), n)], rng.integers(0, 100000, n))])
    # One dictionary shared by every batch, as the IPC file format requires.
    level = pa.DictionaryArray.from_arrays(pa.array(rng.integers(0, 4, n).astype(np.int8)), levels)
    ts = pa.array(rng.integers(0, 2**40, n))
    batches.append(pa.record_batch([ts, host, path, level, msg], names=["ts", "host", "path", "level", "message"]))
table = pa.Table.from_batches(batches)
with ipc.new_file(os.path.join(out, "logs.arrow"), table.schema) as w:
    w.write_table(table)
feather.write_feather(table, os.path.join(out, "logs_lz4.feather"), chunksize=1_000_000)
pq.write_table(table, os.path.join(out, "logs.parquet"))
pq.write_table(table, os.path.join(out, "logs_zstd.parquet"), compression="zstd")
pq.write_table(table, os.path.join(out, "logs_plain.parquet"), use_dictionary=False)
