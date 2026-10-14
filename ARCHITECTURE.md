# fds architecture

How fds is put together: from a directory walk, through the Arrow IPC
reader, to the SIMD loop that finds a term in a string column.

## Code layout

| File | Responsibility |
|---|---|
| `src/main.zig` | Command line; calls `search.run` |
| `src/walk.zig` | Parallel recursive directory walk; knows nothing about searching |
| `src/search.zig` | `run`: thread pool and walk. Per file: map, read messages, find string arrays, search batches in parallel, output |
| `src/arrow.zig` | Arrow IPC: messages, schema, record batch layout, buffers, string arrays, dictionary indices, nesting |
| `src/flatbuf.zig` | A bounds-checked FlatBuffers reader for Arrow's metadata |
| `src/lz4.zig` | LZ4 frame decompression (zstd comes from `std.compress.zstd`) |
| `src/match.zig` | Finding the term in a string array (SIMD), with no I/O; naive reference and randomized test |
| `src/regex.zig` | `-E`: regex parser, compiler and Pike VM, behind the SIMD search as a prefilter |
| `src/c_api.zig` | C ABI (`include/fds.h`): `fds_search` with a callback, over `search.run` |
| `src/bench_match.zig` | Matcher microbenchmark (`zig build bench-match`) |

The layers connect through small interfaces resolved at compile time
(`anytype`, no runtime cost):

- **walk → search.** A *visitor* has a per-directory-task `Local` state and
  a `visitFile(local, file)` function. The walker hands over every regular
  file; `search.zig` keeps the ones named `*.arrow`, `*.feather` or
  `*.arrows` (in any case). A root that is a file skips the walk and is
  searched whatever its name.
- **search → match.** `match.findValues(case, O, off, data, term, sink)`
  calls `sink.onValue(row, value)` for each value of a string array that
  contains `term`. `O` is `i32` (`utf8`) or `i64` (`large_utf8`).
  `regex.findValues` has the same shape for a compiled regex. For values
  that are not stored back to back, `match.contains` and `regex.matches`
  test one value.

## One file, start to finish

```
walk.zig     one task per directory ──► visitFile ──► *.arrow, *.feather, *.arrows only
search.zig   mmap ─► read messages in order ─► schema: find string arrays
                                            ─► dictionary batch: search its values now
                                            ─► record batch: queue a job
             jobs in parallel (Io.Group) ─► each string array ─► match.findValues ─► map to row
             report jobs in order, under the output mutex
```

1. **Map.** The file is `mmap`ed read-only (on Windows, read whole), so
   uncompressed buffers are searched where they lie. Nothing is copied.
2. **Messages.** `arrow.Reader` reads the encapsulated messages in order:
   an optional `0xFFFFFFFF` continuation marker, a 32-bit metadata length,
   a FlatBuffers `Message`, then its body. The file format is the stream
   format with `ARROW1` magic in front and a footer behind. The reader only
   uses the footer's length to know where the messages stop, so both
   formats share one path.
3. **Schema → targets.** `findTargets` walks the schema and lists every
   string array to search (see *Targets* below). If there are none, the
   file is done: a table of numbers is skipped after reading its schema.
   `-c` filters this list by top-level name or full path.
4. **Dictionaries** are searched right away, on the file's thread. Each
   distinct value is searched once, and the result is a bitset over
   dictionary keys. A delta adds values; a replacement (streams only)
   starts over. Either way a *new* `Dictionary` object is made, so the
   batches already queued keep the dictionary that was current for them.
5. **Record batches** become jobs. Each one records its first row in the
   file and its dictionaries as they were at that point.
6. **Jobs run in parallel** in an `Io.Group`, so one large file uses every
   thread, not just one. With one batch the job runs inline. A job finds
   its batch's buffers (`Batch.layout`), searches each target and writes
   matches into its own buffer.
7. **Report.** Under the output mutex the jobs' buffers are written in
   batch order, so a file's matches come out together and in order. If
   reading or a batch failed, the matches before that point are still
   reported, then the error goes to stderr.

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
frame or zstd frame, decoded into memory that belongs to the job.
Decompressed sizes are capped at 1 TiB, and the zstd output is capped at
the declared length plus one byte, so a lying header can't make
decompression run away.

**Checks before searching.** `utf8` and `large_utf8` offsets are checked
once per array: there must be n + 1 of them, non-negative and
non-decreasing, and the last one must be within the data buffer. String
views are checked view by view (each one's length, and its buffer index and
offset if it is stored out of line). Validity bitmaps, index buffers and
list offsets are checked the same way. After that the search can index
without checks. That matters in ReleaseFast, where unchecked out-of-range
indexing is undefined behaviour, not a panic.

## Targets: every string in the schema (`search.zig`)

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

The sink formats `path:column:row` (`--content` adds `:value`, with `\n`
and `\r` escaped) into the job's buffer. For the C API it stores the
value's bytes and position instead, and `report` turns each one into a
`search.Hit`. `c_api.zig` copies a hit into one buffer as NUL-terminated
`path`, `column` and `text` and calls the C callback. A nonzero return
sets a flag that every job and the reporter check, so the search stops
soon.

`libfds.a` links libc so that its threads are pthreads. Without it, Zig
creates threads with its own TLS setup, which a C `main` never runs, and
`fds_search` blocks forever on Linux.

## Testing beyond `zig build test`

- `testdata/make.py` writes the fixtures in `testdata/tree`: one table
  with every kind of string array, between non-string columns (binary, a
  dense union with strings in it, floats), stored three ways (plain, LZ4
  Feather, zstd). There is also a stream with a dictionary delta and a
  replacement, a text file and a truncated file. `search.zig` tests the
  exact matches.
- `testdata/fuzz.py <fds> [iterations] [seed]` is a differential test
  against a Python search over `to_pylist()`. It uses random tables with
  random nesting up to two levels, nulls at every level, dictionaries
  with five index types, slices, 1–10 row batches, three compressions,
  and file or stream format.
- Corrupted files: random byte edits of the fixtures, run through the
  debug build, where an out-of-bounds index panics. 4,000 runs, no panics.

## Cost per byte

For an uncompressed `utf8` column, each byte of string data is loaded twice
by the SIMD scan (the `a` and `b` windows, the second mostly from L1). The
offsets are read once, by the check before searching. Per hit there is a
binary search over the offsets. Validity bitmaps are read only for hits.

On the 2.3 GB benchmark file, fds takes about 125 ms with 16 threads.
That is about 18 GB/s, with 260 ms of system time spread over the threads,
mostly page faults on the mapping. The matcher alone, on data already in
memory, runs at about 23 GB/s on one core.
