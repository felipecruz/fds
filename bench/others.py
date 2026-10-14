"""The same searches as bench/arrow.sh and bench/parquet.sh, in polars and DuckDB.

Usage: python3 bench/others.py <dir>   (needs polars, duckdb, pyarrow)
Times are in-process (Python startup excluded) and count matching rows,
searching the same four string columns fds searches. DuckDB reads Arrow
through pyarrow (zero-copy) and Parquet natively.
"""

import statistics
import sys
import time

import os

import duckdb
import polars as pl
import pyarrow as pa
import pyarrow.ipc as ipc

d = sys.argv[1]
cols = ["host", "path", "level", "message"]


def bench(name, f, runs=5):
    f()
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        n = f()
        times.append(time.perf_counter() - t)
    print(f"{name:44s} {statistics.mean(times) * 1000:7.0f} ms  ({n} rows)")


def polars(path, term, literal=True):
    scan = pl.scan_parquet if path.endswith(".parquet") else pl.scan_ipc
    return lambda: scan(path).filter(pl.any_horizontal(
        [pl.col(c).cast(pl.String).str.contains(term, literal=literal) for c in cols])).select(pl.len()).collect().item()


def duck(path, term):
    where = " OR ".join(f"contains(CAST({c} AS VARCHAR), '{term}')" for c in cols)
    if path.endswith(".parquet"):
        return lambda: duckdb.sql(f"SELECT count(*) FROM read_parquet('{path}') WHERE {where}").fetchone()[0]

    def f():
        t = ipc.open_file(pa.memory_map(path)).read_all()  # zero-copy
        return duckdb.sql(f"SELECT count(*) FROM t WHERE {where}").fetchone()[0]
    return f


for name in ["logs.arrow", "logs.parquet", "logs_zstd.parquet", "logs_plain.parquet"]:
    path = os.path.join(d, name)
    for term in ["host-4242.example", "zqxjv", "checkout"]:
        bench(f"polars {name} {term}", polars(path, term))
        bench(f"duckdb {name} {term}", duck(path, term))
    bench(f"polars {name} regex 'timeout [a-z]+ token'", polars(path, "timeout [a-z]+ token", literal=False))
