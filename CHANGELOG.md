# Changelog

## Unreleased

- **Parquet: strings in lists and maps are searched**, at any depth
  (`tags[]`, `m[].key`, `answers.text[]`), with the same column paths as
  Arrow. Rows come from the repetition levels, including rows that span
  pages.
- **Nothing is skipped silently:** strings in Arrow unions, run-end-encoded
  arrays and list views are reported on stderr
  (`column u not searched (strings in a union)`), and the exit status is 2.
- **`-f FILE`: many terms at once** (one per line, `-` for stdin). From 8
  terms on, an Aho-Corasick automaton searches them in one pass: 10,000
  terms over the 2.3 GB Arrow file in 397 ms, 100,000 in 738 ms
  (`bench/terms.sh`). Works with `-i` and `-w`; with many terms, `-w`
  no longer becomes a regex.
- **Optional PCRE2 regex engine:** `zig build -Dpcre2` runs `-E` with
  PCRE2 and its JIT (`third_party/pcre2`, a git submodule, BSD) instead of
  fds's Pike VM. Same matches, behind the same SIMD prefilter; 1.2–4×
  faster on the Arrow log benchmark, 1.1–2.7× on Parquet
  (`bench/regex.sh`); fastest on every Arrow regex search against DuckDB
  and polars (`bench/regex_others.py`). Full PCRE2 syntax in byte mode. Backtracking is
  bounded per value; a value that hits the bound fails its file's search
  (exit 2). `fds -V` names the engine; compile errors print PCRE2's
  message.
- **Exit status as in grep:** 0 if something matched, 1 if nothing did, 2
  on any error.
- `-l` / `--files-with-matches`, `--count` (`path:column:count`) and
  `-m N` / `--max-count` (per file). `-l` and `-m` stop searching early:
  `-l` finds a common term in a 2.3 GB file in 5 ms.
- `--json`: JSON Lines, `{"path","column","row","value"}`; values that
  aren't UTF-8 as `value_base64`.
- `-w` (whole words), `-e` (several terms; literals stay on the SIMD path,
  one pass each) and `-S` (smart case).
- Colors, and matches highlighted in `--content` output, on a terminal
  (`--color auto|always|never`; `NO_COLOR` is honored).
- **Parquet support.** `.parquet` files are searched too: string columns
  (STRING, ENUM, JSON), at the top level or in structs. Snappy, gzip, zstd,
  LZ4 (raw and Hadoop); data pages v1 and v2; PLAIN, dictionary,
  DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY strings. Dictionary pages
  are skipped undecompressed when no entry matches, and plain pages are
  skipped undecoded when their bytes don't contain the term. Strings in
  lists and maps are not searched yet.
- Built-in Snappy decoder and a bounds-checked Thrift reader; all
  decompression goes through `codecs.zig`, with the same allocation limits
  for every codec.
- `search.zig` is split: the generic layer, plus `search_arrow.zig` and
  `search_parquet.zig`.
- zstd now uses the reference decoder, vendored as a git submodule in
  `third_party/zstd` (v1.5.7, BSD) and compiled from source into `fds` and
  `libfds.a`: about 9× faster than Zig's standard-library decoder. zstd
  Parquet: 1.9 s → 0.32 s on the benchmark (DuckDB: 0.41 s). `fds` now
  links the C library (glibc by default; musl for a static binary). Clone
  with `--recursive`.
- Fixed: files written by polars (`write_ipc`) were rejected as malformed.
  IPC files are now read through their footer, as other readers do.
- Fixed: a corrupted compressed buffer could make fds allocate as much
  memory as its header claimed (48 GB from a 7.6 KB file). Allocations are
  now bounded by what the compressed bytes can produce.
- `testdata/check.py` compares fds with pyarrow on any directory of Arrow
  files; `testdata/mutate.py` corrupts files at random and checks fds
  survives (no crash, hang or runaway memory).
- Checked against files from pyarrow, pandas, polars, Arrow JS and the
  Hugging Face `datasets` cache; cold-cache benchmarks on NVMe.
- CI on Linux and macOS: unit tests, the C example, and the pyarrow checks.

## 0.0.7 — 2026-10-14

First release.

- `fds <path> <term>` searches the string values of every `.arrow`,
  `.feather` and `.arrows` file under `<path>` (or the file `<path>`) and
  prints `path:column:row` (0-based rows); `--content` adds the value.
- Every string array in the schema: `utf8`, `large_utf8`, `utf8_view`,
  dictionary-encoded strings, and strings nested in structs, lists, large
  lists, fixed-size lists and maps (`user.name`, `tags[]`, `m[].key`).
- IPC file and stream formats; LZ4-frame and zstd body compression;
  dictionary deltas and replacements. Built-in LZ4 decoder, no dependencies.
- `-c/--column NAME` (repeatable) limits the search to some columns.
- Large files use every thread: batches are cut into pieces of about 8 MB
  of one column, searched in parallel. On Linux each batch's pages are
  released as soon as it is done, so closing a large file costs nothing.
- Values may contain newlines, and so may the term. In `-E` regexes, `\n` and
  `\r` are escapes, `^`/`$` match at the value's start and end, and `\s`
  includes `\n`.
- Malformed files are reported on stderr and skipped; every offset read
  from a file is bounds-checked.
- C library: `libfds.a` + `fds.h` with `fds_search()` (a callback per
  match: path, column, row, value) and `fds_version()`.
- `-i` ASCII case-insensitive search; `-E` regex (a Pike VM behind a SIMD
  literal prefilter).
- `-j N|auto` threads (default: performance cores on Apple silicon, else
  every CPU).

Tested on Linux (x86-64) only; macOS and Windows builds are untested.
