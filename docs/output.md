# Output

The default is one line per matching value, `path:column:row`. The
examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## The value: `--content`

`path:column:row:value`. Newlines and carriage returns in the value are
printed as `\n` and `\r`, so a match is always one line.

```console
$ fds --content -c note plain.arrow needle
plain.arrow:note:4:needle\nline
```

## Counts: `--count`

`path:column:count`: how many rows match in each column with matches.

```console
$ fds --count parquet/snappy.parquet needle
parquet/snappy.parquet:name:2
parquet/snappy.parquet:note:1
parquet/snappy.parquet:view:2
parquet/snappy.parquet:tags[]:2
parquet/snappy.parquet:user.name:2
parquet/snappy.parquet:cat:2
parquet/snappy.parquet:m[].key:1
parquet/snappy.parquet:m[].value:1
parquet/snappy.parquet:pair[]:2
```

## Files: `-l`

`-l` (`--files-with-matches`) prints each file that has a match, and stops
searching it at the first: on a 2.3 GB file with a common term, 5 ms.

```console
$ fds -l parquet needle
parquet/snappy.parquet
parquet/v2_delta.parquet
parquet/plain_gzip.parquet
parquet/lz4.parquet
```

## The first matches: `-m N`

`-m N` (`--max-count`) stops after N matches in each file: its first N,
in the file's order.

```console
$ fds -m 2 parquet/snappy.parquet needle
parquet/snappy.parquet:name:0
parquet/snappy.parquet:view:1
```

## JSON: `--json`

JSON Lines: one object per match, `{"path","column","row","value"}`. A
value (or path) that isn't valid UTF-8 comes as `value_base64` (or
`path_base64`) instead, since a JSON string can't hold arbitrary bytes.
With `-l` the objects are `{"path"}`; with `--count`,
`{"path","column","count"}`.

```console
$ fds --json -c note plain.arrow needle
{"path":"plain.arrow","column":"note","row":4,"value":"needle\nline"}
$ fds --json --count -c tags -c cat parquet/snappy.parquet needle
{"path":"parquet/snappy.parquet","column":"tags[]","count":2}
{"path":"parquet/snappy.parquet","column":"cat","count":2}
```

Ready for `jq`, or for `pandas.read_json(..., lines=True)`:

```console
$ fds --json parquet/snappy.parquet needle | jq -r .column | sort | uniq -c
      2 cat
      1 m[].key
      1 m[].value
      2 name
      1 note
      2 pair[]
      2 tags[]
      2 user.name
      2 view
```

## Colors

On a terminal, paths are magenta, columns cyan, rows green and the
matched text bold red, as in ripgrep. `--color always` keeps the colors
through a pipe (`fds --color always ... | less -R`). `--color never`, or
the `NO_COLOR` environment variable, turns them off.

## Speed

`checkout` in a 2.3 GB Arrow file, 4.4 million matches: printing them all
150 ms, `--count` 68 ms, `-m 1` 21 ms, `-l` 5 ms.
