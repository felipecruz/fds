"""The same searches as bench/arrow.sh, in polars and DuckDB.

Usage: python3 bench/others.py <logs.arrow>   (needs polars, duckdb, pyarrow)
Times are in-process (Python startup excluded) and count matching rows,
searching the same four string columns fds searches.
"""

import statistics
import sys
import time

import duckdb
import polars as pl
import pyarrow as pa
import pyarrow.ipc as ipc

path = sys.argv[1]
cols = ["host", "path", "level", "message"]


def bench(name, f, runs=5):
    f()
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        n = f()
        times.append(time.perf_counter() - t)
    print(f"{name:44s} {statistics.mean(times) * 1000:7.0f} ms  ({n} rows)")


def polars(term, literal=True):
    return lambda: pl.scan_ipc(path).filter(pl.any_horizontal(
        [pl.col(c).cast(pl.String).str.contains(term, literal=literal) for c in cols])).select(pl.len()).collect().item()


def duck(term):
    def f():
        t = ipc.open_file(pa.memory_map(path)).read_all()  # zero-copy
        where = " OR ".join(f"contains(CAST({c} AS VARCHAR), '{term}')" for c in cols)
        return duckdb.sql(f"SELECT count(*) FROM t WHERE {where}").fetchone()[0]
    return f


for term in ["host-4242.example", "zqxjv", "checkout"]:
    bench(f"polars contains {term}", polars(term))
    bench(f"duckdb contains {term}", duck(term))
bench("polars regex 'timeout [a-z]+ token'", polars("timeout [a-z]+ token", literal=False))
