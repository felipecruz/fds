# Security

fds reads files it doesn't control: datasets downloaded from the web, a
Hugging Face cache, files someone sent you. A file is untrusted input, and
fds is written for that.

## What a file can't do

Whatever its bytes, a file must not make fds:

- **read or write out of bounds.** Every offset, length and count read
  from a file is checked against the bytes actually there before it is
  used. This matters more than usual: the release binary and `libfds.a`
  are built ReleaseFast, where Zig's own safety checks are off.
- **allocate without bound.** No size a file claims decides an allocation
  alone. Counts that compress well (run-length levels, Parquet pages) are
  capped (16 M values per page), memory is per Parquet page rather than
  per column chunk, and an Arrow schema holds at most about a million
  fields.
- **hang.** Lengths are checked against the bytes left before a loop runs
  on them, nesting is capped (Thrift structs, schemas), and work that
  grows with a file's structure (Arrow dictionary deltas) is linear.
- **control your terminal.** Values, column names, map keys and file
  paths are printed with control bytes escaped (`\xNN`, line breaks as
  `\n` and `\r`), on stdout and stderr, so a file can't send escape
  sequences (window titles, clipboard writes, links) or forge output
  lines. `--json` escapes them as JSON does.
- **stall the search** by putting a FIFO or a device where a file was:
  only regular files are opened, and opening never blocks.

Strings fds can't search, and files it can't read, are reported on stderr
with exit status 2: a "no match" never hides a skipped column.

## How it is tested

- `testdata/mutate.py` corrupts the test files at random (it flips,
  overwrites or replaces a few bytes) and searches each one with the
  debug build, which panics on any out-of-bounds access. fds must not
  crash, take more than 10 seconds or use more than 1 GB. CI runs it on
  every push, on Linux and macOS.
- `testdata/fuzz.py` writes random tables with pyarrow and checks that fds
  finds exactly what Python finds.
- `zig build test` feeds every decoder (LZ4, Snappy, gzip, zstd, Thrift,
  run-length, delta) truncated and lying inputs.
- The code had a security review in October 2026; what it found and how
  it was fixed is in the [changelog](CHANGELOG.md) ("Hardening").

## Known limits

- **A file truncated while fds is searching it** can crash fds with
  SIGBUS, as with any tool that maps files into memory. Changing a file
  as it is read is not something a file's contents can do.
- **PCRE2 backtracks** (`zig build -Dpcre2`): a pattern like `(a+)+$` can
  take exponential time on some values. Each match is bounded, and a
  value that reaches the bound is an error for its file (exit status 2),
  never a silent "no match". fds's own regex engine runs in linear time.
- **Patterns are trusted more than files.** A regex is checked for size
  and nesting depth, but an application that passes its users' patterns
  to `fds_search` should prefer fds's own engine to PCRE2.
- **The C library** prints its warnings (unreadable files, unsearched
  columns) to stderr.

## Reporting a vulnerability

Please report it privately, with GitHub's "Report a vulnerability" button
on the repository's Security tab, rather than in a public issue. A file
that crashes, hangs or exhausts memory is the most useful thing to attach.
