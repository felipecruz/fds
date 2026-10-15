# Formats

The examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## Arrow

Files (`.arrow`, `.feather`: Feather v2) and streams (`.arrows`), as
written by pyarrow, pandas, polars, Arrow JS and Hugging Face `datasets`.
Uncompressed, or with LZ4 or zstd buffers.

Searched: `utf8` (`string`), `large_utf8` (`large_string`) and
`utf8_view` (`string_view`), dictionary-encoded or not (pandas
categoricals: each distinct value is searched once), at the top level or
in structs, lists, large lists, fixed-size lists and maps, at any depth.

## Parquet

As written by pyarrow, pandas, polars, DuckDB and fastparquet.
Snappy, gzip, zstd, LZ4 or uncompressed; data pages v1 and v2; `PLAIN`,
dictionary, `DELTA_LENGTH_BYTE_ARRAY` and `DELTA_BYTE_ARRAY` strings.

Searched: `BYTE_ARRAY` columns annotated as text (`STRING`, `ENUM` or
`JSON`), at the top level or in structs, lists and maps, at any depth.
Pages that can't match are skipped: a dictionary-encoded page whose
dictionary has no match is never decompressed, and a plain page whose
bytes don't hold the term is never decoded.

## What fds didn't search

fds never skips strings silently. Strings it can't search, in Arrow
unions, run-end-encoded arrays and list views, are reported on stderr,
and so are files it can't read; matches found elsewhere are still
printed, and the exit status is 2.

```console
$ fds -c name -c u plain.arrow needle
fds: plain.arrow: column u not searched (strings in a union)
plain.arrow:name:0
plain.arrow:name:4
$ fds -l truncated.arrow needle
fds: truncated.arrow: not a valid Arrow IPC file
```

`-c` leaves out what it doesn't select, warnings included:

```console
$ fds -c name plain.arrow needle; echo "exit $?"
plain.arrow:name:0
plain.arrow:name:4
exit 0
```

Binary columns (Arrow `binary`, Parquet `BYTE_ARRAY` with no text
annotation) are not text, and are not searched.

## Not supported

Feather v1 (2016), big-endian Arrow files, encrypted Parquet files,
Parquet columns stored in other files, and the LZO and Brotli codecs.
Such files are reported and skipped.
