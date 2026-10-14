# Changelog

## Unreleased

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
