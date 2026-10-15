# Searching

```
fds [options] <path> <term>
```

`<path>` is a file or a directory. The examples run in `testdata/tree`
(see [Running the examples](README.md#running-the-examples)).

## A file

One line per matching value: `path:column:row`.

```console
$ fds parquet/snappy.parquet needle
parquet/snappy.parquet:name:0
parquet/snappy.parquet:view:1
parquet/snappy.parquet:view:3
parquet/snappy.parquet:tags[1]:0
parquet/snappy.parquet:tags[0]:3
parquet/snappy.parquet:tags[1]:3
parquet/snappy.parquet:user.name:0
parquet/snappy.parquet:cat:1
parquet/snappy.parquet:m[needle].key:1
parquet/snappy.parquet:m[k]:0
parquet/snappy.parquet:pair[1]:1
parquet/snappy.parquet:name:4
parquet/snappy.parquet:note:4
parquet/snappy.parquet:user.name:4
parquet/snappy.parquet:cat:4
parquet/snappy.parquet:pair[0]:5
```

- **Rows are 0-based** and count from the start of the file, across row
  groups (Parquet) or record batches (Arrow), so `df.iloc[row]` finds them.
- **The column** is where in the row the value is: a struct field is
  `user.name`, a list's element 1 is `tags[1]`, a map's value for key
  `k` is `m[k]`. See [Columns](columns.md).
- A file is searched whatever its name: the format comes from its first
  bytes.

`--content` adds the value. Newlines in it are printed as `\n`, so one
match is always one line (and other control characters as `\xNN`; see
[Output](output.md)).

```console
$ fds --content parquet/snappy.parquet 'a needle'
parquet/snappy.parquet:name:4:a needle here
```

## A directory

Every `.arrow`, `.feather`, `.arrows` and `.parquet` file under it, at any
depth, searched in parallel: one task per directory, and large columns cut
into pieces, so all CPUs work on one big file too.

```console
$ fds -l . needle
fds: ./plain.arrow: column u not searched (strings in a union)
fds: ./sub/lz4.feather: column u not searched (strings in a union)
fds: ./sub/zstd.arrow: column u not searched (strings in a union)
fds: ./truncated.arrow: not a valid Arrow IPC file
./sub/lz4.feather
./sub/zstd.arrow
./plain.arrow
./deltas.arrows
./polars.arrow
./parquet/snappy.parquet
./parquet/v2_delta.parquet
./parquet/plain_gzip.parquet
./parquet/lz4.parquet
```

(`-l` prints only the files that match.) Problems go to stderr, and the
exit status is then 2: here a truncated file, and union columns fds can't
search (see [Formats](formats.md)).

## Order

Files come out in no fixed order. Within a file, matches are ordered by
row group (or record batch), then column, then row; `-m N` keeps a file's
first N in that order. A file's matches are never interleaved with
another's.

## Threads

`-j N` sets the number of worker threads. The default, `-j auto`, is every
CPU, or the performance cores on Apple silicon. `-j 1` is fully serial.
