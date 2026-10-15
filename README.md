# fds

**Fast data search: an experimental project to bring fast string search
to the file formats of data science and machine learning.**

Data lives in columnar files, not text files, and finding a string in them
usually means loading them into a dataframe or a database first. fds
searches the files directly, grep-style: point it at a directory and a
term, and it prints every matching value with its file, column and row.

**Status: experimental.** Formats: Arrow IPC (`.arrow`, `.feather`,
`.arrows`) and Parquet (`.parquet`). The command line, the output and the C
library may all change.

It is a command-line tool and a C library, about 2,800 lines of Zig. The
one piece of third-party code is zstd's reference decompressor, built from
source with the rest (`third_party/`); PCRE2 can be built in too, as an
optional regex engine. Two ideas make it fast:

1. **Threads:** one task per directory, and inside a file one per piece:
   about 8 MB of one string column.
2. **SIMD:** compare 32 bytes at a time (16 on NEON) over a whole string
   column in one pass.

An Arrow string column is all of its values back to back in one buffer,
plus an offsets array. That is exactly the input the SIMD loop wants. The
file is memory-mapped and the column searched in place: no parsing into
rows, no copies (unless the file is compressed).

Parquet stores strings encoded and compressed, so pages must be decoded
first, but most pages never are: a dictionary-encoded page is skipped,
undecompressed, when no dictionary entry matched, and a plain page is
skipped, undecoded, when its raw bytes don't contain the term.

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

**Cold cache**, the same files on an NVMe drive (btrfs), evicted from the
page cache before every run (DuckDB and polars each in a fresh process,
timing only the query):

| No-match search, cold | **fds** | DuckDB 1.5 | polars 2.0 |
|:---|---:|---:|---:|
| Uncompressed `.arrow` (2.3 GB) | **485 ms** | 692 ms | 867 ms |
| LZ4 Feather (1.1 GB) | **561 ms** | 1,038 ms | 885 ms |

Cold, fds reads at about 4.6 GB/s, the speed of the drive.

### Parquet

The same 20 million rows as Parquet, warm page cache, same machine, 16
threads each. DuckDB and polars read Parquet natively.

| No-match search | **fds** | DuckDB 1.5 | polars 2.0 |
|:---|---:|---:|---:|
| pyarrow defaults: Snappy, dictionaries (707 MB) | **275 ms** | 324 ms | 470 ms |
| No dictionaries, plain pages (792 MB) | **335 ms** | 459 ms | 583 ms |
| zstd (535 MB) | **321 ms** | 406 ms | 593 ms |

- Rare terms: 302 ms with Snappy (DuckDB 346 ms), 344 ms with zstd
  (DuckDB 466 ms).
- Common terms are about even: 459 ms with Snappy and 479 ms with zstd,
  against DuckDB's 480 ms and 465 ms. fds prints every match; DuckDB
  only counts rows.

The script is `bench/parquet.sh`; `bench/others.py` times DuckDB and polars.

### Regex engines

`-E` runs fds's own engine (a Pike VM: linear time, no dependencies) by
default, or PCRE2 with its JIT when built with `zig build -Dpcre2`. Both
sit behind the same SIMD literal prefilter and report the same matches.
The same 20 million rows, warm page cache, 16 threads:

| Pattern | Arrow: fds VM | Arrow: PCRE2 | Parquet: fds VM | Parquet: PCRE2 |
|:---|---:|---:|---:|---:|
| `timeout [a-z]+ token` | 265 ms | **93 ms** | 577 ms | **395 ms** |
| `-w checkout` | 332 ms | **173 ms** | 670 ms | **501 ms** |
| `\d{5}$` | 1,287 ms | **578 ms** | 1,213 ms | **770 ms** |
| `[xz]{3}` (no match) | 504 ms | **144 ms** | 692 ms | **415 ms** |
| `error\|fatal` | 1,520 ms | **384 ms** | 1,799 ms | **665 ms** |
| `-i TIMEOUT \w+ TOKEN` | 261 ms | **104 ms** | 586 ms | **400 ms** |
| `^/api/v[0-9]+/checkout/\d+$` | 103 ms | **84 ms** | 323 ms | **301 ms** |
| `(fast\|slow) (queue\|cache)` | 835 ms | **223 ms** | 1,306 ms | **529 ms** |

- **PCRE2 is 1.2–4× faster on Arrow** and 1.1–2.7× on Parquet, where
  decompression takes a larger share of the time. It gains the most on
  alternations and on patterns with no required literal, where most values
  reach the regex engine.
- **PCRE2 backtracks**, so a pattern like `(a+)+$` can take exponential
  time on some values. Each match is bounded; a value that reaches the
  bound fails the search of its file (exit status 2) instead of being
  taken as not matching. fds's own engine has no such case.
- PCRE2 accepts its full syntax (lazy quantifiers, lookaround,
  backreferences), in byte mode with the same semantics for `.`, `$`,
  `\d \w \s \b` and `-i` as fds's engine.

The script is `bench/regex.sh` (results in `results/regex-*.md`).

## What gets searched

Every string value the schema has. In **Arrow** files:

- `utf8` (`string`), `large_utf8` (`large_string`) and `utf8_view` (`string_view`);
- dictionary-encoded strings (pandas categoricals): each distinct value
  is searched once, then rows are matched by their index;
- strings nested in structs, lists, large lists, fixed-size lists and maps,
  at any depth.

Not searched: binary columns, and strings inside unions, run-end-encoded
or list-view arrays.

In **Parquet** files: `BYTE_ARRAY` columns annotated as text (`STRING`,
`ENUM` or `JSON`), at the top level or inside structs (`user.name`).
Not yet: strings inside lists and maps.

## Usage

```
fds [options] <path> <term>
fds [options] -e <term> [-e <term>]... <path>

matching:
  -i, --ignore-case    ASCII case-insensitive
  -S, --smart-case     ignore case unless a term has an upper-case letter
  -E, --regex          terms are regexes: . [a-z] [^0-9] \d \w \s \b ^ $ * + ? {n,m} | ( ) \n
  -w, --word           whole words only
  -e, --regexp TERM    a term; repeat to match any of several
  -c, --column NAME    search only this column: a top-level name, or a path
                       like user.name or tags[]; repeatable
output:
  --content            print path:column:row:value instead of path:column:row
  -l, --files-with-matches   print only the files that match
  --count              print path:column:count for each column with matches
  -m, --max-count N    stop after N matches in each file
  --json               JSON Lines (see below)
  --color WHEN         auto (default: a terminal, unless NO_COLOR is set),
                       always or never
other:
  -j N|auto            worker threads (default: auto = all CPUs; performance
                       cores on Apple silicon)
```

`<path>` is a directory (every `.arrow`, `.feather`, `.arrows` and
`.parquet` file under it is searched) or a single file (searched whatever
its name; the format comes from its first bytes). Output is one line per
matching value:

```
$ fds data needle --content
data/events.arrow:name:0:needle
data/events.arrow:user.name:4:needles
data/events.arrow:tags[]:3:needle
data/events.arrow:m[].value:0:needle
```

- **Rows are 0-based** and count from the start of the file, across record
  batches or row groups, so `df.iloc[row]` finds them.
- **Column paths:** a struct field is `user.name`, a list element is
  `tags[]`, and map keys and values are `m[].key` and `m[].value`. A row
  whose list holds several matches is reported once.
- **Order:** files come out in no fixed order. Within a file, matches are
  ordered by record batch, then column, then row; `-m N` keeps the file's
  first N in that order.
- `^` and `$` match at the start and end of the value. In `--content`
  output, newlines in values are printed as `\n`. On a terminal, paths,
  columns, rows and the matched text are colored, as in ripgrep.
- **Exit status**, as in grep: 0 if something matched, 1 if nothing did,
  2 if a file couldn't be read (even if others matched).

**`--json`** prints one object per line, ready for `jq` or
`pandas.read_json(..., lines=True)`:

```
{"path":"data/events.arrow","column":"note","row":4,"value":"needle\nline"}
```

A value (or path) that isn't valid UTF-8 is given as `"value_base64"`
instead, since JSON strings can't hold arbitrary bytes. With `-l`, the
objects are `{"path"}`; with `--count`, `{"path","column","count"}`.

**Speed of the modes**, `checkout` in the 2.3 GB Arrow file (4.4 M
matches): printing them all 150 ms, `--count` 68 ms, `-m 1` 21 ms, `-l`
5 ms (it stops at the first match). `-e a -e b` searches each literal with
the SIMD loop (272 ms for two); `-w` and `-E` alternations run the regex
engine on candidate values.

## Building

```
git clone --recursive https://github.com/felipecruz/fds   # or: git submodule update --init
zig build                                                  # Zig 0.17
```

`zig build` puts the binary in `zig-out/release/fds` (and a debug build in
`zig-out/debug/fds`, `libfds.a` in `zig-out/lib`). It links the system C
library, which zstd's decoder needs for `malloc`. For a fully static
binary with no runtime dependencies, build against musl:
`zig build -Dtarget=x86_64-linux-musl` (about 10% slower on zstd files).

`zig build -Dpcre2` runs `-E` with PCRE2 (`third_party/pcre2`, BSD) instead
of fds's own regex engine: faster, with fuller syntax, but backtracking
(see [Regex engines](#regex-engines)). `fds -V` says which engine a binary has.

## The C library

`libfds.a` includes zstd, so a C program links just it (and libc):

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

**Arrow:**

- The IPC file format (`.arrow`, `.feather`, which is Feather v2) and the
  IPC stream format (`.arrows`), including old streams without the
  continuation marker.
- Buffers compressed with LZ4 frame (what pyarrow's `write_feather` uses
  by default) or zstd. LZ4 is built in (`src/lz4.zig`); zstd is the
  reference decoder (`third_party/zstd`).
- Dictionary batches, including deltas and (in streams) replacements.
- Not supported: Feather v1 (2016) and big-endian files. Such files are
  reported on stderr and skipped.

Checked against files written by pyarrow (`ipc`, `feather`, pandas
`to_feather`), polars (`write_ipc`, `write_ipc_stream`; all compression
and compat levels), Arrow JS, and the Hugging Face `datasets` cache
(Arrow streams named `.arrow`), with `testdata/check.py`.

**Parquet:**

- Codecs: uncompressed, Snappy, gzip, zstd, LZ4 (`LZ4_RAW` and the older
  Hadoop-framed `LZ4`). Snappy and LZ4 decoders are built in, zstd is the
  reference decoder, gzip comes from Zig's standard library. Not
  supported: LZO and Brotli.
- Data pages v1 and v2; string encodings `PLAIN`, `RLE_DICTIONARY` /
  `PLAIN_DICTIONARY`, `DELTA_LENGTH_BYTE_ARRAY` and `DELTA_BYTE_ARRAY`.
- Not supported: encrypted files, and columns stored in other files.

Checked against files written by pyarrow and pandas, polars, DuckDB
(including its v2 mode), fastparquet, and Parquet files from the Hugging
Face Hub (`squad`, `ag_news`, `imdb`).

A malformed file is reported (`fds: <path>: not a valid Parquet file`, or
`Arrow IPC`) and skipped; matches found before the problem are still
printed. Every offset, length and count read from a file is checked first,
and no size a file claims can make fds allocate more than the data could
produce.

## Limitations

- **Tested on Linux and macOS** (CI runs every test on both). Windows
  builds have never been run; there the whole file is read into memory
  instead of being mapped.
- **A file truncated while it is being searched** can crash fds (SIGBUS),
  as with any tool that maps files.
- **ASCII semantics.** `-i`, `\w` and `\b` are ASCII-only.
- **String views** are searched one value at a time, because their bytes
  are not stored back to back. That is slower than `utf8` columns.
- **Parquet:** strings inside lists and maps are not searched yet. A
  column chunk is searched by one thread, so a file with fewer chunks than
  threads doesn't use them all.
- **Parquet pages are capped at 16 M values**, far above what writers
  produce, so that a corrupted header can't make fds allocate without
  bound. A larger page is reported as unsupported.

## Correctness

`zig build test` runs:
- the SIMD search against a naive per-value search (randomized, including
  matches that span two values, which must not count);
- the regex VM against a backtracking reference matcher;
- every codec (LZ4, Snappy, gzip, zstd) on real compressor output, with
  every truncation and lies about the size;
- the Thrift reader, the run-length and delta decoders;
- searches of `testdata/tree`: the same table stored as Arrow (plain, LZ4,
  zstd) and Parquet (Snappy with dictionaries, v2 pages with
  `DELTA_BYTE_ARRAY` and zstd, plain gzip with tiny pages, LZ4), a stream
  with dictionary deltas, a file written by polars and an empty Parquet
  file (`testdata/make.py` writes them), whole and cut into tiny pieces;
- the C API, called the way C would call it.

Three scripts compare fds with pyarrow (they need `pyarrow`, and
`polars` for `make.py`):

- `testdata/check.py <fds> <path> <term>` reads every Arrow file under a
  path with pyarrow, searches it in Python, and checks that fds prints
  exactly the same matches and reports exactly the files pyarrow can't
  read. Use it on your own data.
- `testdata/fuzz.py <fds> [n] [seed] [--parquet]` writes random tables
  (random string types, nesting, nulls, dictionaries, slices, batch sizes,
  compression, file or stream; with `--parquet`, random codecs, page
  versions, string encodings, page and row group sizes) and does the same
  check.
- `testdata/mutate.py <debug fds>` corrupts the test files at random. fds
  must not crash (the debug build panics on any out-of-bounds access),
  hang or use more than 1 GB on any of them.

CI (`.github/workflows/ci.yml`) runs all of it on Linux and macOS.

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, from the Arrow
  reader to the SIMD loop.
- [CHANGELOG.md](CHANGELOG.md).
