# fds architecture

How fds is put together: from a directory walk, through the Arrow IPC and
Parquet readers, to the SIMD loop that finds a term in a string column.

## Code layout

| File | Responsibility |
|---|---|
| `src/main.zig` | Command line; calls `search.run` |
| `src/walk.zig` | Parallel recursive directory walk; knows nothing about searching |
| `src/search.zig` | `run`: thread pool and walk. Per file: detect the format, run its pieces in parallel, report. Also the `Matcher` and the output |
| `src/search_arrow.zig` | An Arrow file or stream into pieces: read messages, find string arrays, search dictionaries, cut batches |
| `src/search_parquet.zig` | A Parquet file into pieces: one per string column chunk |
| `src/map.zig` | The file's bytes: map, close, and `release` parts that won't be read again |
| `src/linux.zig` | Linux-only code (used by `map.zig`): dropping a part's pages early |
| `src/arrow.zig` | Arrow IPC: messages, schema, record batch layout, buffers, string arrays, dictionary indices, nesting |
| `src/flatbuf.zig` | A bounds-checked FlatBuffers reader for Arrow's metadata |
| `src/parquet.zig` | Parquet: footer, schema, column chunks, pages, levels and string encodings; searching a chunk |
| `src/thrift.zig` | A bounds-checked Thrift compact-protocol reader for Parquet's metadata |
| `src/codecs.zig` | Every codec behind one call, with allocation limits |
| `src/lz4.zig` | LZ4 frames and blocks |
| `src/snappy.zig` | Snappy blocks |
| `src/zstd.zig` | zstd, through the reference decoder in `third_party/zstd` |
| `src/match.zig` | Finding the term in a string array (SIMD), with no I/O; naive reference and randomized test |
| `src/regex.zig` | `-E`: regex parser, compiler and Pike VM, behind the SIMD search as a prefilter |
| `src/pattern.zig` | The command line's terms (`-e`, `-w`, `-S`, `-E`) into literals or one regex |
| `src/c_api.zig` | C ABI (`include/fds.h`): `fds_search` with a callback, over `search.run` |
| `src/bench_match.zig` | Matcher microbenchmark (`zig build bench-match`) |

The layers connect through small interfaces resolved at compile time
(`anytype`, no runtime cost):

- **walk → search.** A *visitor* has a per-directory-task `Local` state and
  a `visitFile(local, file)` function. The walker hands over every regular
  file; `search.zig` keeps the ones named `*.arrow`, `*.feather`,
  `*.arrows` or `*.parquet` (in any case). A root that is a file skips the
  walk and is searched whatever its name. Either way the format comes
  from the file's first bytes (`PAR1` is Parquet), not its name.
- **search → format.** A format module has `plan(file, arena, matcher)`,
  which adds the file's pieces in output order, and a `Job` type (one
  variant of `search.Job`) with `search(...)` and `finish(...)` for one
  piece. A piece's matches go to `Piece.record(row, value)`, which writes
  the output line (or keeps the value for the C callback) and reports a
  row only once.
- **search → match.** `match.findValues(case, O, off, data, term, sink)`
  calls `sink.onValue(row, value)` for each value of a string array that
  contains `term`. `O` is `i32` (`utf8`) or `i64` (`large_utf8`).
  `regex.findValues` has the same shape for a compiled regex. For values
  that are not stored back to back, `match.contains` and `regex.matches`
  test one value.

## One Arrow file, start to finish

(Parquet: see *Parquet* below; the steps around it, mapping, running
pieces, releasing and reporting, are the same.)

```
walk.zig     one task per directory ──► visitFile ──► data files only
map.zig      mmap the file
search_arrow.zig  read messages in order ─► schema: find string arrays
                                         ─► dictionary batch: search its values now
                                         ─► record batch: cut into pieces
search.zig   pieces in parallel (Io.Group) ─► match.findValues ─► map to row
                                           ─► batch's last piece done: release its pages
             report pieces in order, under the output mutex
map.zig      munmap (nothing left to tear down on Linux)
```

1. **Map.** `map.Map` maps the file read-only (on Windows, reads it
   whole), so uncompressed buffers are searched where they lie. Nothing is
   copied.
2. **Messages.** `arrow.Reader` hands out the schema, then dictionary and
   record batches. A *stream* is read in order: each message is an
   optional `0xFFFFFFFF` continuation marker, a 32-bit metadata length, a
   FlatBuffers `Message`, then its body. A *file* (`ARROW1` magic at both
   ends) is read through its footer, which holds the schema and a block
   (offset, metadata length, body length) for every dictionary and record
   batch. The spec says a file holds a valid stream before the footer, but
   polars writes something else there, and pyarrow never looks at it, so
   the footer is the only reliable way in.
3. **Schema → targets.** `findTargets` walks the schema and lists every
   string array to search (see *Targets* below). If there are none, the
   file is done: a table of numbers is skipped after reading its schema.
   `-c` filters this list by top-level name or full path.
4. **Dictionaries** are searched right away, on the file's thread. Each
   distinct value is searched once, and the result is a bitset over
   dictionary keys. A delta adds values; a replacement (streams only)
   starts over. Either way a *new* `Dictionary` object is made, so the
   batches already queued keep the dictionary that was current for them.
5. **Record batches** are cut into *pieces* (see *Pieces* below). A
   batch's `BatchWork` keeps its layout (`Batch.layout`), its first row
   in the file and its dictionaries as they were at that point, and
   all its pieces share it.
6. **Pieces run in parallel** in an `Io.Group`. When every thread is busy,
   `async` runs the piece inline, so the file's own thread works too. A
   piece searches one string array, or a range of one, and writes matches
   into its own buffer.
7. **Release.** Each batch counts its unfinished pieces. The one that
   brings the count to zero calls `map.release` on the batch's body (see
   *Releasing pages* below).
8. **Report.** Under the output mutex, the pieces' buffers are written in
   order (batch, column, row), so a file's matches come out together and
   in order. If reading or a piece failed, the matches before that point
   are still reported, then the error goes to stderr.

### Pieces

A record batch is a poor unit of work: there may be fewer batches than
threads, and batches of 1 M rows on 16 threads ran as two waves, the
second of only 3 batches. So `FileSearch.cut` splits each batch by column
and, for top-level string columns, by rows. Each piece of a column covers
about `Options.piece_bytes` (8 MB) of offsets and data: the row count is
the column's rows divided by `bytes / piece_bytes`. 8 MB was fastest in a
sweep from 1 to 32 MB. Smaller pieces add overhead per piece; larger ones
bring the uneven waves back.

`Batch.stringRange` returns rows `from..to` of a string array, checking
only that range's offsets or views. The values keep their absolute
offsets into the data buffer, so `match.findValues` needs no change; the
sink adds `Strings.first` to turn a value's index back into a row.

These arrays are not cut, and are searched whole by one piece:
- **nested** strings, whose leaf indices don't map to row ranges;
- **dictionary-encoded** columns, which are one pass over small indices;
- **compressed** batches, where every piece would decompress the whole
  buffer;
- arrays under 2 × `piece_bytes`, and anything malformed (the error then
  comes from the search).

### Releasing pages

Closing a mapping is not free: `munmap` tears down every page-table entry
on one thread, holding the process's memory-map lock exclusively. For the
2.3 GB benchmark file that took 66 ms, about as long as searching it on
16 threads, and it happened after the search was over.

So as soon as a batch's last piece is done, `Map.release` hands its body
back. On Linux, `linux.dropPages` calls `madvise(MADV_DONTNEED)` on the
whole pages inside it. That takes the lock shared, so the threads drop
their batches in parallel, while others are still searching, and the
final `munmap` finds almost nothing left. Nothing reads a batch's body
after its pieces finish: matches are copied into the pieces' buffers, and
dictionary values live in their own messages. If something did read it,
the page would simply be faulted back in from the page cache. Other systems
do nothing on `release`; their pages go at `munmap`, as before.

The OS-specific code is in `linux.zig` alone, and `map.zig` calls it behind
a comptime `builtin.os.tag == .linux` check, so other targets never compile
it. Prefaulting (`MAP_POPULATE`), huge pages and `MADV_SEQUENTIAL` were
tried as well and didn't help; `MAP_POPULATE` was 2× slower.

## The Arrow reader (`src/arrow.zig`, `src/flatbuf.zig`)

Arrow's metadata is FlatBuffers. `flatbuf.zig` is the minimum needed to
read it: tables through their vtables, scalars with defaults, strings,
vectors of tables, structs and scalars. **Every offset is checked against
the buffer before it is followed**, so a malformed file is
`error.Malformed`, never an out-of-bounds read. Nesting depth is capped at
64, so a cyclic schema can't recurse forever.

**Layout.** A record batch is a list of *field nodes* (length, null count),
one per field in a pre-order walk of the schema, and a list of *buffers*.
How many buffers each field takes depends on its type, so to find a column
you have to walk every field before it. That is `Batch.place`:

| Type | Buffers |
|---|---|
| null, run-end encoded | 0 |
| struct, fixed-size list, sparse union | 1 |
| fixed width (int, float, date, …), list, large list, map, dense union, dictionary indices | 2 |
| binary, utf8, large binary, large utf8, list view, large list view | 3 |
| binary view, utf8 view | 2 + that field's count in `variadicBufferCounts` |

Children follow their parent. A dictionary-encoded field has no children
in a record batch: it is indices only, and its values come in dictionary
batches.

**Buffers.** `Batch.buffer(i)` returns a slice of the body. With body
compression, every non-empty buffer starts with its uncompressed length
as an `i64` (-1 means it was stored uncompressed). The rest is one LZ4
frame or zstd frame, decoded into memory that belongs to the job. The
declared length is only a claim; see *Decompression* below.

**Checks before searching.** `utf8` and `large_utf8` offsets are checked
once per array: there must be n + 1 of them, non-negative and
non-decreasing, and the last one must be within the data buffer. String
views are checked view by view (each one's length, and its buffer index and
offset if it is stored out of line). Validity bitmaps, index buffers and
list offsets are checked the same way. After that the search can index
without checks. That matters in ReleaseFast, where unchecked out-of-range
indexing is undefined behaviour, not a panic.

## Targets: every string in the schema (`search_arrow.zig`)

A *target* is one string array: a field whose type is `utf8`, `large_utf8`
or `utf8_view`, or a dictionary-encoded field whose values have one of those
types. It can sit at any depth under structs, lists, large lists,
fixed-size lists and maps. Unions, run-end-encoded arrays and list views
are not entered, though `Batch.place` still steps over them correctly.

Each target records its column path and the nested fields above it:

| Schema | Path |
|---|---|
| top-level `name: string` | `name` |
| `user: struct<name: string>` | `user.name` |
| `tags: list<string>` | `tags[]` |
| `m: map<string, string>` | `m[].key`, `m[].value` |
| `events: list<struct<msg: string>>` | `events[].msg` |

**From a nested value to a row.** The leaf string array is searched as a
whole, like any other. Then each matching index is mapped up one level at
a time (`arrow.Level.parent`):

- **struct:** child `j` belongs to entry `j`;
- **fixed-size list** of size `s`: entry `j / s`;
- **list, large list, map:** the entry `p` with `off[p] <= j < off[p + 1]`,
  found by binary search. Matches arrive in increasing order, so each
  level keeps a cursor and the search starts where the last one ended.

A value counts only if it and every entry above it are valid (not null).
A value that no entry points at is skipped. The top-level index plus the
batch's first row is the reported row. Several matches in one row's list
come out as a single report, because rows arrive in order and the
previous row is remembered.

**Dictionary targets** don't search the batch at all. The dictionary's
values were searched when its batch was read, which gave a bitset of
matching keys. Each row's index is looked up in that bitset, and if no key
matched, the column is skipped entirely. A low-cardinality column (a
`level` with four values in 20 million rows) costs one pass over its
indices.

## Parquet (`src/parquet.zig`, `src/thrift.zig`, `src/search_parquet.zig`)

A Parquet file is `PAR1`, column chunks, a footer (FileMetaData, in
Thrift's compact protocol), its length and `PAR1` again. `parquet.open`
reads the footer: the schema, and for each row group where each column's
chunk is, its codec and its value count.

**Schema → columns.** The schema is a flattened tree: a pre-order list of
elements, where a group says how many children follow. Walking it gives
the leaves in chunk order, each with its path, its maximum definition
level (one per optional or repeated field on the way) and its maximum
repetition level (one per repeated field). A leaf is searched if it is a
`BYTE_ARRAY` annotated as text (logical type STRING, ENUM or JSON, or the
converted types UTF8, ENUM, JSON) and nothing above it is repeated. Then
every value is one row: top-level columns and struct fields (`user.name`).
Leaves under lists or maps have repetition levels, and values no longer
map one-to-one to rows; they are not searched yet.

**Pieces.** One per searched column per row group, in output order (row
group, then column). Each chunk is its own byte range of the file, so a
finished piece releases it right away.

**A chunk** is pages, each a Thrift `PageHeader` then its bytes:
1. An optional **dictionary page**: decompressed, its values decoded
   (PLAIN: a 4-byte length, then the bytes) into offsets and data, and
   searched once, giving a bitset of matching keys.
2. **Data pages**, v1 or v2. In v1 the whole page is compressed, and holds
   the definition levels (a 4-byte length, then the run-length/bit-packing
   hybrid) then the values. In v2 the levels come first, uncompressed, with
   their lengths in the header, and only the values are compressed.

**Skipping pages.** Two checks run before any real work:
- A **dictionary-encoded** page whose dictionary had no matching entry
  can't match. It is skipped before it is even decompressed. This is the
  common case for a rare term in a low-cardinality column.
- A **PLAIN** page is decompressed, but before its values are decoded,
  `Matcher.mayMatch` scans its raw bytes for the term (or a regex's required
  literal) with the SIMD loop. If the term is nowhere, no value can hold it.

**Decoding.** Definition levels say which rows hold a value (level = the
maximum) and which are null. Values come in:
- `PLAIN`: copied out of their length prefixes into back-to-back data, so
  `match.findValues` runs on them as on an Arrow column;
- `RLE_DICTIONARY` / `PLAIN_DICTIONARY`: a bit width, then keys in the
  hybrid encoding, each looked up in the dictionary's bitset;
- `DELTA_LENGTH_BYTE_ARRAY`: lengths (`DELTA_BINARY_PACKED`), then the
  bytes back to back, so they are searched in place;
- `DELTA_BYTE_ARRAY`: each value a prefix of the previous one plus a
  suffix; rebuilt, then searched.
A match's index among the page's values maps back to its row through the
list of present rows, plus the page's first row in the chunk and the row
group's first row in the file.

**Limits.** Run-length encoding makes huge counts cheap to write, so
counts are never trusted alone. A page may hold at most 16 M values
(`max_page_values`; real pages hold thousands). A delta header's count
must equal the number of present values. Rebuilt `DELTA_BYTE_ARRAY`
values are capped at 256 MB per page. Everything else is checked against
the bytes actually there.

## Decompression (`src/codecs.zig`)

Every codec, for both formats, goes through `codecs.decompress(codec, src,
n)`, where `n` is the size the file states. A corrupted file can state any
size, so `n` is a claim, and nothing is allocated for it beyond what `src`
could produce:
- **LZ4** expands at most 255× and **Snappy** about 22×, so a larger claim
  is rejected before allocating anything.
- **zstd** and **gzip** have no small bound. Their output buffer starts
  small, grows only as bytes come out, and stops one byte past the claim.

Before this rule, a 7.6 KB corrupted Arrow file could make fds allocate
48 GB (`testdata/mutate.py` found it).

The Snappy and LZ4 decoders are built in (`snappy.zig`, `lz4.zig`), and
gzip is Zig's standard library.

**zstd** is the reference decoder, a git submodule in `third_party/zstd`
pinned to a release. `build.zig` compiles only its decompressor
(`lib/common`, `lib/decompress`, plus its x86-64 assembly Huffman decoder),
always optimized, into the binary and into `libfds.a`. `zstd.zig` declares
the few C functions it calls. Zig's standard-library decoder is correct
but ran at about 175 MB/s per core, against about 1,550 MB/s for the
reference one. On the benchmark, that took zstd Parquet from 1.9 s to
0.32 s.

zstd allocates with `malloc`, so `fds` links the C library: glibc by
default (a dynamic binary), or musl with `-Dtarget=x86_64-linux-musl` for a
static one. `zstd.decompress` keeps the rule above: it allocates the
claimed size up front only when the frame header states the same size and
the ratio is at most 64×; otherwise it streams, growing the output as it
comes.

## The SIMD loop (`src/match.zig`)

### Searching a column

`findValues` scans `data[off[0]..off[n]]`, the bytes of all n values, as
one run, with the first-and-last-byte filter described below. A verified
match at byte `pos` is handed to `onMatch`:

1. **Which value?** `rowOf` finds the row `r` with
   `off[r] <= pos < off[r + 1]` by binary search, starting from the
   previous row (hits arrive in increasing order).
2. **Inside the value?** If the match runs past `off[r + 1]`, it spans two
   values: `"foo"` then `"bar"` stored as `foobar` contains `obar`, but no
   value does. The scan resumes at `pos + 1`.
3. **Report and skip.** Otherwise `sink.onValue(r, value)` is called and
   the scan resumes at `off[r + 1]`. Each value is reported at most once,
   and the rest of a matching value is never scanned.

So the per-byte work is just the scan, and the offsets are touched only on
hits. Values can contain any byte, newlines included.

### The loop

```zig
const vec_len = std.simd.suggestVectorLength(u8) orelse 16;   // 32 with AVX2, 16 on NEON
outer: while (i + vec_len <= end) {
    const a: Vec = data[i..][0..vec_len].*;            // bytes where the term would start
    const b: Vec = data[i + n - 1 ..][0..vec_len].*;   // bytes where it would end
    var mask: Mask = first.eqlMask(a) & last.eqlMask(b);
    while (mask != 0) : (mask &= mask - 1) {           // each set bit = one candidate
        const pos = i + @ctz(mask);
        if (eql(case, data[pos..][0..n], term)) {
            i = try ctx.onMatch(pos) orelse return;    // where to resume, or stop
            continue :outer;
        }
    }
    i += vec_len;
}
```

This is Wojciech Muła's "generic SIMD" substring search:

- Load `a` holds the candidate start bytes. Load `b` is the same window
  shifted by `n - 1`, holding the candidate end bytes.
- `a == first` and `b == last` each give one boolean per lane, and `&`
  keeps only the positions where **both** ends match.
- `@ctz` picks the leftmost candidate, and `mask &= mask - 1` moves to the
  next. Only a surviving candidate pays for a full comparison.

For a typical term nearly every block has `mask == 0`. The cost is then two
loads, two compares, an `and` and a branch per 32 bytes (on AVX2). On NEON,
LLVM tests the mask with `umaxv` and builds a real bitmask only when some
lane is set, because NEON has no movemask instruction.

**Tail.** Once fewer than `vec_len` candidate positions remain, a scalar
loop checks each one. That happens once per column, not once per value.

**Bounds.** `i + vec_len <= end` is the same as
`i + n - 1 + vec_len <= data.len`, so both loads stay in range.

### Ignoring case (`-i`)

`find` takes `case` as a comptime parameter, so the case-sensitive loop is
untouched. In the insensitive copy, each end byte of the term is kept as
its lower-case form plus a `fold` vector (`0x20` for letters, `0`
otherwise), and the block is compared as `(v | fold) == lower`, one extra
OR per load. Setting bit 5 maps `A`–`Z` onto `a`–`z`, and no other byte
lands there, so the fold creates no false candidates. `[` and `{` differ
only in bit 5, which is why non-letters get `fold = 0`. Candidates are
verified with `std.ascii.eqlIgnoreCase`. Only ASCII is folded.

### Correctness

`findValuesNaive` searches each value on its own with `std.mem.indexOf`.
The randomized test (`"SIMD search matches naive search"`) builds 20,000
columns over the alphabet `abAB`, with empty values, columns that start at
a nonzero offset and bytes after the last value. It checks `findValues`
with `i32` and `i64` offsets, both cases, and `contains`, against the naive
search. The tiny alphabet makes matches across value boundaries frequent,
and those must not be reported. Every 50th column is long, to cover
many full blocks.

## Regex (`-E`, `src/regex.zig`)

A regex search is a literal search plus a filter:

```
pattern ─► parse (tree) ─► compile (NFA program) ─► required literal
column  ─► match.findValues(literal) ─► candidate value ─► Pike VM: any match? ─► sink
```

1. **Parse** (recursive descent) into `Node`s. Every byte-consuming
   construct is a 256-bit byte set, so the VM has one "consume"
   instruction.
2. **Compile** to a Thompson NFA. `e{n,m}` is expanded, and programs are
   capped at 10,000 instructions.
3. **Required literal:** the longest run of bytes every match must contain
   (`PM_` in `PM_[A-Z_]+`). Alternations and optional parts contribute
   nothing.
4. **Search.** With a literal, `match.findValues` runs on it with a
   `Filter` sink that passes a value on only if the VM accepts it. Without
   one (`[0-9a-f]{16}`), every value goes to the VM. For string views and
   dictionary values, `regex.matches` does the same for one value.
5. **Pike VM.** Threads advance in lockstep, one byte at a time, stopping at
   the first `match`: only "does this value match?" is needed. That is
   O(value × program) with no backtracking. `first`, the set of bytes that
   can start a match, lets the VM skip ahead while no thread is alive.

`^` and `$` are the start and end of the value; `.` matches any byte,
newline included; `\s` includes `\n`; `\n`, `\r` and `\t` are escapes.
`\w`, `\s`, `\b` and `-i` are ASCII-only.

Each job has its own `Vm` (scratch arrays sized from the program). Jobs
run in parallel and the VM is not shared.

**Tests:** table-driven syntax and error cases; 5,000 random patterns
against a backtracking matcher, asserting that every match contains the
required literal (so the prefilter never drops one); and a check that the
prefiltered and every-value paths agree on a column.

## Output and the C API

Each piece records its own matches (`Piece.record`), in its own buffer,
and `Searcher.report` writes a file's pieces in order under the output
mutex. The output modes are decided in those two places:

- **Matches** (the default): `record` formats one line per match,
  `path:column:row[:value]`, or a JSON object with `--json`. With colors,
  `writeContent` highlights each match in the value: `Matcher.span` finds
  it, through `match.indexOf` for literals or `regex.span` for regexes (an
  anchored run of the VM per candidate start, keeping the longest end;
  only on values known to match, and not on values over 1 MB).
- **`-l`**: the first match ends the piece (`record` returns
  `error.Enough`) and sets the file's `found` flag, so pieces not yet
  started are skipped. One match anywhere is all `-l` needs.
- **`--count`**: `record` only counts; `report` adds up the pieces'
  counts per column, in schema order.
- **`-m N`**: a piece stops after N matches of its own (no piece can
  contribute more), and `report` keeps the first N of the file, in order.

`record` reports a row once even if several list elements in it match:
rows arrive in order, so it remembers the last.

`run` returns a `Summary` (did anything match; did any file fail), which
`main` turns into the exit status: 0, 1 or 2, as grep.

**Several literals** (`-e a -e b`) stay on the SIMD path: `Matcher` runs
one pass per literal over a column, marking matching values in a bitset,
then hands them to the sink once each, in order. A regex alternation
would have no required literal, so the VM would run on every value
(1.16 s against 0.27 s for two terms on the benchmark).

For the C API, the sink stores the value's bytes and position instead,
and `report` turns each one into a `search.Hit`. `c_api.zig` copies a hit
into one buffer as NUL-terminated `path`, `column` and `text` and calls
the C callback. A nonzero return sets a flag that every piece and the
reporter check, so the search stops soon.

`libfds.a` links libc so that its threads are pthreads. Without it, Zig
creates threads with its own TLS setup, which a C `main` never runs, and
`fds_search` blocks forever on Linux.

## Testing beyond `zig build test`

- `testdata/make.py` writes the fixtures in `testdata/tree`: one table
  with every kind of string array, between non-string columns (binary, a
  dense union with strings in it, floats), stored as Arrow three ways
  (plain, LZ4 Feather, zstd) and as Parquet four ways (Snappy with
  dictionaries in two row groups; v2 pages, `DELTA_BYTE_ARRAY` and zstd;
  plain gzip with tiny pages; LZ4 with `DELTA_LENGTH_BYTE_ARRAY`). There
  is also a stream with a dictionary delta and a replacement, a polars
  file, an empty Parquet file, a text file and a truncated file.
  `search.zig` tests the exact matches.
- `testdata/fuzz.py <fds> [iterations] [seed] [--parquet]` is a
  differential test against a Python search over `to_pylist()`. It uses
  random tables with random nesting up to two levels, nulls at every
  level, dictionaries with five index types, slices, 1–10 row batches,
  three compressions, and file or stream format. With `--parquet`: five
  codecs, dictionaries on or off, page v1 or v2, `PLAIN` or delta string
  encodings, pages from 64 bytes and row groups of 1–50 rows.
- `testdata/check.py <fds> <path> <term>` runs the same comparison on
  existing files: those from other writers (pandas, polars, Arrow JS,
  DuckDB, fastparquet) and real datasets (Hugging Face).
- `testdata/mutate.py <debug fds> [runs] [seed] [files...]` makes random
  byte edits to files and searches them with the debug build, where an
  out-of-bounds index panics. fds must exit cleanly within 10 s and 1 GB.
  Runs so far: 4,500 corrupted Arrow files and 5,500 corrupted Parquet
  files (pyarrow, DuckDB, polars, fastparquet), with no failures.

## Cost per byte

For an uncompressed `utf8` column, each byte of string data is loaded twice
by the SIMD scan (the `a` and `b` windows, the second mostly from L1). The
offsets are read once, by the check before searching. Per hit there is a
binary search over the offsets. Validity bitmaps are read only for hits.

On the 2.3 GB benchmark file, fds takes about 65–70 ms with 16 threads,
about 35 GB/s. The search pieces read at about 50 GB/s together, close to
this machine's memory bandwidth, and system time is mostly page faults on
the mapping. The matcher alone, on data already in memory, runs at about
23 GB/s on one core.
