# fds

**Fast data search: an experimental project to bring fast string search
to the file formats of data science and machine learning.**

![fds searching 20 million rows of Arrow and Parquet logs](docs/demo.gif)

Data lives in columnar files, not text files, and finding a string in them
usually means loading them into a dataframe or a database first. fds
searches the files directly, grep-style: point it at a directory and a
term, and it prints every matching value with its file, column and row.

Regexes run on fds's own engine, or optionally on PCRE2, which is faster
(`zig build -Dpcre2`; see [Regex engines](#regex-engines)).

Two ideas make it fast:

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

## Examples

On the test files in this repository (`cd testdata/tree`): one table, as
Arrow and as Parquet, with every kind of string column.

```console
$ fds --content parquet/snappy.parquet 'a needle'
parquet/snappy.parquet:name:4:a needle here
$ fds -w --content -c name -c user plain.arrow needle
plain.arrow:name:0:needle
plain.arrow:user.name:0:needle
plain.arrow:name:4:a needle here
$ fds --count -c tags -c cat parquet/snappy.parquet needle
parquet/snappy.parquet:tags[]:2
parquet/snappy.parquet:cat:2
$ fds -E --content -c name -c tags parquet/snappy.parquet '^needle$'
parquet/snappy.parquet:name:0:needle
parquet/snappy.parquet:tags[1]:0:needle
parquet/snappy.parquet:tags[0]:3:needle
$ printf 'haystack\nbob\n' | fds -f - --content parquet/snappy.parquet
parquet/snappy.parquet:name:3:haystack
parquet/snappy.parquet:user.name:2:bob
$ fds --json -c note plain.arrow needle
{"path":"plain.arrow","column":"note","at":"note","row":4,"value":"needle\nline"}
```

**[The documentation](docs/README.md)**, also at
[felipecruz.github.io/fds](https://felipecruz.github.io/fds/), has every option, each example
with its real output (CI checks them), and the same pages in the terminal
(`fds help`) and as a man page (`man fds`).

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
| Regex `timeout [a-z]+ token` | **285 ms** | 750 ms | 519 ms |

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
The same 20 million rows, warm page cache, 16 threads, against DuckDB
(`regexp_matches`, RE2) and polars (`str.contains`, Rust regex). All four
find the same matches for every pattern.

| Arrow (2.3 GB) | fds VM | fds PCRE2 | DuckDB 1.5 | polars 2.0 |
|:---|---:|---:|---:|---:|
| `timeout [a-z]+ token` | 265 ms | **93 ms** | 750 ms | 527 ms |
| `-w checkout` (4.5 M matches) | 332 ms | **173 ms** | 1,098 ms | 548 ms |
| `\d{5}$` (18 M matches) | 1,287 ms | **578 ms** | 717 ms | 599 ms |
| `[xz]{3}` (no match) | 504 ms | **144 ms** | 1,092 ms | 509 ms |
| `error\|fatal` (9.5 M matches) | 1,520 ms | **384 ms** | 1,108 ms | 564 ms |
| `-i TIMEOUT \w+ TOKEN` | 261 ms | **104 ms** | 771 ms | 578 ms |
| `^/api/v[0-9]+/checkout/\d+$` | 103 ms | **84 ms** | 369 ms | 493 ms |
| `(fast\|slow) (queue\|cache)` | 835 ms | **223 ms** | 1,106 ms | 558 ms |

| Parquet (Snappy, 707 MB) | fds VM | fds PCRE2 | DuckDB 1.5 | polars 2.0 |
|:---|---:|---:|---:|---:|
| `timeout [a-z]+ token` | 577 ms | **395 ms** | 968 ms | 525 ms |
| `-w checkout` | 670 ms | **501 ms** | 1,300 ms | 530 ms |
| `\d{5}$` | 1,213 ms | 770 ms | 912 ms | **520 ms** |
| `[xz]{3}` | 692 ms | **415 ms** | 1,304 ms | 485 ms |
| `error\|fatal` | 1,799 ms | 665 ms | 1,321 ms | **548 ms** |
| `-i TIMEOUT \w+ TOKEN` | 586 ms | **400 ms** | 990 ms | 585 ms |
| `^/api/v[0-9]+/checkout/\d+$` | 323 ms | **301 ms** | 558 ms | 459 ms |
| `(fast\|slow) (queue\|cache)` | 1,306 ms | **529 ms** | 1,318 ms | 572 ms |

- **With PCRE2, fds is fastest on every Arrow search** and on six of
  eight Parquet searches. With its own engine, it beats DuckDB on most
  patterns; on Arrow it loses to polars on alternations and `\d{5}$`, and
  on Parquet polars is faster on most patterns.
- **fds prints every match; DuckDB and polars only count rows.** That
  is most of the time on the patterns that match millions of values. With
  `--count`, fds PCRE2 takes 279 ms for `\d{5}$` and 228 ms for
  `error|fatal` on Arrow, and 520 ms and 514 ms on Parquet, even with
  polars there.
- **PCRE2 is 1.2–4× faster than fds's engine on Arrow** and 1.1–2.7× on
  Parquet, where decompression takes a larger share of the time. It gains
  the most on alternations and on patterns with no required literal,
  where most values reach the regex engine.
- **PCRE2 backtracks**, so a pattern like `(a+)+$` can take exponential
  time on some values. Each match is bounded; a value that reaches the
  bound fails the search of its file (exit status 2) instead of being
  taken as not matching. fds's own engine, RE2 and Rust's regex have no
  such case.
- PCRE2 accepts its full syntax (lazy quantifiers, lookaround,
  backreferences), in byte mode with the same semantics for `.`, `$`,
  `\d \w \s \b` and `-i` as fds's engine.

The scripts are `bench/regex.sh` (results in `results/regex-*.md`) and
`bench/regex_others.py`.

### Many terms

`--count -f` on the same 2.3 GB Arrow file and 740 MB Parquet file. From
8 terms on, fds searches them all in one Aho-Corasick pass, so the time
hardly depends on how many there are ([Many terms](docs/many-terms.md)):

| Terms | Arrow (2.3 GB) | Parquet (740 MB) |
|---:|---:|---:|
| 8 | 339 ms | 648 ms |
| 100 | 337 ms | 570 ms |
| 1,000 | 347 ms | 578 ms |
| 10,000 | 397 ms | 643 ms |
| 100,000 | 738 ms | 1,035 ms |

The term files are random strings, 8 to 24 bytes, with one in a hundred a
host name that occurs in the data. Up to 7 terms, one SIMD pass each is
faster (about 40 ms per term on the Arrow file). The script is
`bench/terms.sh`.

## What gets searched

Every string value the schema has, at any depth: in **Arrow** files,
`utf8`, `large_utf8` and `utf8_view` columns, dictionary-encoded or not,
and in structs, lists, fixed-size lists and maps; in **Parquet** files,
`BYTE_ARRAY` columns annotated as text, in structs, lists and maps.
Arrow files and streams, uncompressed or LZ4 or zstd; Parquet with
Snappy, gzip, zstd, LZ4 or none, pages v1 and v2, every string encoding.
Checked against files written by pyarrow, pandas, polars, DuckDB,
fastparquet, Arrow JS and Hugging Face `datasets` and Hub files.
[Formats](docs/formats.md) has the details.

**Nothing is skipped silently.** Binary columns are not text and are not
searched. Strings fds can't search, inside Arrow unions, run-end-encoded
arrays or list views, are reported on stderr
(`fds: <path>: column u not searched (strings in a union)`), and the exit
status is 2, as for an unreadable file: a "no match" is never an
incomplete search. A malformed file is reported and skipped; every
offset, length and count read from a file is checked first, and no size a
file claims can make fds allocate more than the data could produce.

## Usage

```
fds [options] <path> <term>
fds [options] -e <term> [-e <term>]... <path>
fds [options] -f <file> <path>
```

`<path>` is a directory (every `.arrow`, `.feather`, `.arrows` and
`.parquet` file under it) or a single file (whatever its name: the format
comes from its first bytes). `-i -E -w -e -f -l -m` work as in grep,
`-S` as in ripgrep; `-c NAME` searches one column (counting is
`--count`), and `--content`, `--json`, `--color` and `-j` do the rest.
`fds --help` lists them, and [docs/](docs/README.md) and `man fds`
explain each. Output is one line per matching value, with its place in
the row:

```
$ fds data needle --content
data/events.arrow:name:0:needle
data/events.arrow:user.name:4:needles
data/events.arrow:tags[1]:3:needle
data/events.arrow:m[color]:0:needle
```

- **Rows are 0-based** and count from the start of the file, across record
  batches or row groups, so `df.iloc[row]` finds them.
- **Where in the row:** a struct field is `user.name`, a list's element 1
  is `tags[1]`, a map's value for key `color` is `m[color]` (and the key
  itself `m[color].key`). `-c` and `--count` use column paths, without
  positions: `tags[]`, `m[].value`.
- **Order:** files come out in no fixed order. Within a file, matches are
  ordered by record batch, then column, then row.
- **`--json`** gives JSON Lines, `{"path","column","at","row","value"}`,
  for `jq` or `pandas.read_json(..., lines=True)`.
- **Exit status**, as in grep: 0 if something matched, 1 if nothing did,
  2 if a file couldn't be read (even if others matched).

**`-f terms.txt`** searches thousands of terms in one pass (an
Aho-Corasick automaton): 10,000 terms take about as long as 8 (see
[Many terms](#many-terms)). That is the shape of scanning jobs: does any
of these benchmark questions appear in my training data, which rows hold
one of these customer IDs?

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
    printf("%s:%s:%llu:%s\n", m->path, m->at, (unsigned long long)m->row, m->text);
    return 0;   /* nonzero stops the search */
}

fds_search("data", "needle", FDS_IGNORE_CASE, 0, on_match, NULL);
```

[`examples/count.c`](examples/count.c) is a complete program (`zig build
c-example -- testdata/tree needle`), and [Scripting](docs/scripting.md#the-c-library)
says what the callback can count on.

## Limitations

- **Tested on Linux and macOS** (CI runs every test on both). Windows
  builds have never been run; there the whole file is read into memory
  instead of being mapped.
- **A file truncated while it is being searched** can crash fds (SIGBUS),
  as with any tool that maps files.
- **ASCII semantics.** `-i`, `\w` and `\b` are ASCII-only.
- **String views** are searched one value at a time, because their bytes
  are not stored back to back. That is slower than `utf8` columns.
- **Arrow:** strings inside unions, run-end-encoded arrays and list views
  are reported, not searched (see [What gets searched](#what-gets-searched)).
- **Parquet:** a column chunk is searched by one thread, so a file with
  fewer chunks than threads doesn't use them all. In a list column, every
  page is decompressed to count its rows, even when its dictionary rules
  out a match.
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

- [docs/](docs/README.md), also at
  [felipecruz.github.io/fds](https://felipecruz.github.io/fds/): the
  documentation, topic by topic.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the code works, from the Arrow
  reader to the SIMD loop.
- [CHANGELOG.md](CHANGELOG.md).
