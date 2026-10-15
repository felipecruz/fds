"""The regex searches of bench/regex.sh, in DuckDB (RE2) and polars (Rust regex).

Usage: python3 bench/regex_others.py <dir>   (needs polars, duckdb, pyarrow)
Times are in-process (Python startup excluded) and count matching rows over
the same four string columns fds searches. Before timing, each pattern's
total of matching (column, row) pairs is printed, to compare with
`fds --count`. DuckDB reads Arrow through pyarrow (zero-copy) and Parquet
natively.
"""

import os
import statistics
import sys
import time

import duckdb
import polars as pl
import pyarrow as pa
import pyarrow.ipc as ipc

d = sys.argv[1]
cols = ["host", "path", "level", "message"]

# fds's flags as regex syntax: -w is \b...\b, -i is (?i).
patterns = [
    r"timeout [a-z]+ token",
    r"\bcheckout\b",
    r"\d{5}$",
    r"[xz]{3}",
    r"error|fatal",
    r"(?i)TIMEOUT \w+ TOKEN",
    r"^/api/v[0-9]+/checkout/\d+$",
    r"(fast|slow) (queue|cache)",
]


def bench(name, f, runs=5):
    f()
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        n = f()
        times.append(time.perf_counter() - t)
    print(f"{name:52s} {statistics.mean(times) * 1000:7.0f} ms  ({n} rows)", flush=True)


def polars(path, expr):
    scan = pl.scan_parquet if path.endswith(".parquet") else pl.scan_ipc
    return lambda: scan(path).filter(pl.any_horizontal(
        [pl.col(c).cast(pl.String).str.contains(expr) for c in cols])).select(pl.len()).collect().item()


def duck(path, select):
    if path.endswith(".parquet"):
        return lambda: duckdb.sql(f"SELECT {select} FROM read_parquet('{path}')").fetchone()[0]

    def f():
        t = ipc.open_file(pa.memory_map(path)).read_all()  # zero-copy
        return duckdb.sql(f"SELECT {select} FROM t").fetchone()[0]
    return f


def rows(expr):
    return "count(*) FILTER (WHERE " + " OR ".join(
        f"regexp_matches(CAST({c} AS VARCHAR), '{expr}')" for c in cols) + ")"


def pairs(expr):
    return " + ".join(f"count(*) FILTER (WHERE regexp_matches(CAST({c} AS VARCHAR), '{expr}'))" for c in cols)


for name in ["logs.arrow", "logs.parquet"]:
    path = os.path.join(d, name)
    for expr in patterns:
        print(f"duckdb {name} '{expr}': {duck(path, pairs(expr))()} matches", flush=True)
        bench(f"duckdb {name} '{expr}'", duck(path, rows(expr)))
        bench(f"polars {name} '{expr}'", polars(path, expr))
