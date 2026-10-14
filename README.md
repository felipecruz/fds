# fds

**Fast data search: an experimental project to bring fast string search
to the file formats of data science and machine learning.**

Data lives in columnar files, not text files, and finding a string in them
usually means loading them into a dataframe or a database first. fds
searches the files directly, grep-style: point it at a directory and a
term, and it prints every matching value with its file, column and row.

**Status: experimental (0.0.7).** The first format is Arrow IPC (`.arrow`,
`.feather`, `.arrows`). The command line, the output and the C library may
all change. It has been tested on one Linux machine.

It is a command-line tool and a C library, about 1,800 lines of Zig with
no dependencies. Two ideas make it fast:

1. **Threads:** one task per directory, and inside a file one per piece:
   about 8 MB of one string column.
2. **SIMD:** compare 32 bytes at a time (16 on NEON) over a whole string
   column in one pass.

An Arrow string column is all of its values back to back in one buffer,
plus an offsets array. That is exactly the input the SIMD loop wants. The
file is memory-mapped and the column searched in place: no parsing into
rows, no copies (unless the file is compressed).

## Results

20 million rows of log data (2.3 GB of strings: `host`, `path`, `level`
as a dictionary, `message`), one uncompressed `.arrow` file, warm page
cache, AMD Ryzen 9 6950H (8 cores, 16 threads), Linux. All three tools use
16 threads; Python startup is not counted for DuckDB and polars.

| Search (all string columns) | **fds** | DuckDB 1.5 | polars 2.0 |
|:---|---:|---:|---:|
| Rare `host-4242.example` (3,989 rows) | **74 ms** | 230 ms | 488 ms |
| No match `zqxjv` | **71 ms** | 195 ms | 485 ms |
| Common `checkout` (4.4 M rows) | **174 ms** | 256 ms | 500 ms |
| Regex `timeout [a-z]+ token` | **285 ms** | — | 519 ms |

- **About 33 GB/s on an uncompressed file**, close to the memory bandwidth
  of this laptop. The matcher alone runs at about 23 GB/s per core, and
  one thread gets through the whole file in 192 ms.
- **Compressed files cost more:** the same table as LZ4 Feather (1.1 GB)
  takes 325 ms, almost all of it decompression.
- Each match is printed as one line (4.5 million of them for `checkout`),
  where DuckDB and polars only count rows.

The scripts are `bench/arrow.sh` and `bench/others.py`. The output
matches DuckDB and polars row for row on all four searches.

## What gets searched

Every string value the schema has:

- `utf8` (`string`), `large_utf8` (`large_string`) and `utf8_view` (`string_view`);
- dictionary-encoded strings (pandas categoricals): each distinct value
  is searched once, then rows are matched by their index;
- strings nested in structs, lists, large lists, fixed-size lists and maps,
  at any depth.

Not searched: binary columns, and strings inside unions, run-end-encoded
or list-view arrays.

## Usage

```
fds [-j N|auto] [-i] [-E] [-c COLUMN]... [--content] <path> <term>

  -j N|auto          worker threads (default: auto = all CPUs; performance
                     cores on Apple silicon)
  -i, --ignore-case  ASCII case-insensitive
  -E, --regex        <term> is a regex: . [a-z] [^0-9] \d \w \s \b ^ $ * + ? {n,m} | ( ) \n
  -c, --column NAME  search only this column: a top-level name, or a path
                     like user.name or tags[]; repeatable
  --content          print path:column:row:value instead of path:column:row
```

`<path>` is a directory (every `.arrow`, `.feather` and `.arrows` file under
it is searched) or a single file (searched whatever its name). Output is
one line per matching value:

```
$ fds data needle --content
data/events.arrow:name:0:needle
data/events.arrow:user.name:4:needles
data/events.arrow:tags[]:3:needle
data/events.arrow:m[].value:0:needle
```

- **Rows are 0-based** and count from the start of the file, across record
  batches, so `df.iloc[row]` finds them.
- **Column paths:** a struct field is `user.name`, a list element is
  `tags[]`, and map keys and values are `m[].key` and `m[].value`. A row
  whose list holds several matches is reported once.
- **Order:** files come out in no fixed order. Within a file, matches are
  ordered by record batch, then column, then row.
- `^` and `$` match at the start and end of the value. In `--content`
  output, newlines in values are printed as `\n`.

`zig build` puts the binary in `zig-out/release/fds`.

From C:

```c
#include <stdio.h>
#include "fds.h"   /* zig-out/include, link zig-out/lib/libfds.a */

static int on_match(void *ctx, const fds_match *m) {
    printf("%s:%s:%llu:%s\n", m->path, m->column, (unsigned long long)m->row, m->text);
    return 0;   /* nonzero stops the search */
}

fds_search("data", "needle", FDS_IGNORE_CASE, 0, on_match, NULL);
```

## Formats

- The IPC file format (`.arrow`, `.feather`, which is Feather v2) and the
  IPC stream format (`.arrows`), including old streams without the
  continuation marker.
- Buffers compressed with LZ4 frame (what pyarrow's `write_feather` uses
  by default) or zstd. Both decoders are built in: LZ4 is about 90 lines
  in `src/lz4.zig`, zstd comes from Zig's standard library.
- Dictionary batches, including deltas and (in streams) replacements.
- Not supported: Feather v1 (2016) and big-endian files. Such files are
  reported on stderr and skipped.

A malformed file is reported (`fds: <path>: not a valid Arrow IPC file`) and
skipped; matches found before the problem are still printed. Every offset
read from a file is bounds-checked first.

## Limitations

- **Tested on one Linux machine.** It builds for macOS and Windows, but
  those builds have not been run on this version. On Windows the whole
  file is read into memory instead of being mapped.
- **A file truncated while it is being searched** can crash fds (SIGBUS),
  as with any tool that maps files.
- **ASCII semantics.** `-i`, `\w` and `\b` are ASCII-only.
- **String views** are searched one value at a time, because their bytes
  are not stored back to back. That is slower than `utf8` columns.

## Correctness

`zig build test` runs:
- the SIMD search against a naive per-value search (randomized, including
  matches that span two values, which must not count);
- the regex VM against a backtracking reference matcher;
- the LZ4 decoder on pyarrow output, with every truncation;
- searches of `testdata/tree`: the same table stored plain, LZ4 and zstd,
  plus a stream with dictionary deltas (`testdata/make.py` writes them);
- the C API, called the way C would call it.

`testdata/fuzz.py` is a differential test. It writes random tables (random
string types, nesting, nulls, dictionaries, slices, batch sizes,
compression, file or stream) and compares fds with a Python search over
`to_pylist()`. 1,400 tables (about 11,000 matches) agree. Separately, 4,000
randomly corrupted test files were run through the debug build, where any
out-of-bounds access would panic; there were no crashes.

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, from the Arrow
  reader to the SIMD loop.
- [CHANGELOG.md](CHANGELOG.md).
