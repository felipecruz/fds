---
title: FDS
section: 1
header: User Commands
---

# NAME

fds - search the string values of Arrow and Parquet files

# SYNOPSIS

**fds** [*options*] *path* *term*\
**fds** [*options*] **-e** *term* [**-e** *term*]... *path*\
**fds** [*options*] **-f** *file* *path*\
**fds help** [*topic*]

# DESCRIPTION

**fds** searches every string value of every Arrow IPC file (*.arrow*,
*.feather*, *.arrows*) and Parquet file (*.parquet*) under *path*, or of
*path* itself if it is a file (whatever its name), and prints
*path*:*column*:*row* for each value that contains *term*.

Rows are 0-based and count from the start of the file. The column is the
value's place in its row: *user.name* for a struct field, *tags[1]* for
element 1 of a list, *m[key]* for the value of a map's entry *key* and
*m[key].key* for its key. Each matching value is a line. Options that
take a column (**-c**) and **\--count** use column paths, with positions
left out: *tags[]*, *m[].value*, *m[].key*. Files come out in no fixed order;
within a file, matches are ordered by row group (or record batch), column,
then row.

Strings fds can't search (in Arrow unions, run-end-encoded arrays and list
views) and files it can't read are reported on standard error.

# OPTIONS

## Matching

**-i**, **\--ignore-case**
:   Match ASCII letters regardless of case.

**-S**, **\--smart-case**
:   Ignore case unless a term has an upper-case letter.

**-E**, **\--regex**
:   Terms are regular expressions: **. [a-z] [\^0-9] \\d \\w \\s \\b \^ \$
    \* + ? {n,m} | ( )** and **\\n \\r \\t**. **\^** and **\$** match at the
    start and end of the value. Built with PCRE2 (**zig build -Dpcre2**;
    see **-V**), the full PCRE2 syntax.

**-w**, **\--word**
:   Match whole words only.

**-e**, **\--regexp** *term*
:   A term to search for; repeat it to match any of several.

**-f**, **\--file** *file*
:   Terms, one per line (**-** for standard input); empty lines are
    ignored. From 8 terms on, they are searched together in one pass, so
    thousands are fine. Repeatable, and can be mixed with **-e**.

**-c**, **\--column** *name*
:   Search only this column: a top-level name (everything under it), or a
    path such as *user.name* or *tags[]*. Repeatable.

## Output

**\--content**
:   Also print the value: *path*:*column*:*row*:*value*. Newlines in it
    are printed as **\\n**.

**-l**, **\--files-with-matches**
:   Print only the files that match; each file's search stops at its first
    match.

**\--count**
:   Print *path*:*column*:*count* for each column with matches.

**-m**, **\--max-count** *n*
:   Stop after *n* matches in each file.

**\--json**
:   JSON Lines: **{"path","column","at","row","value"}**, *column* being
    the column path and *at* the place, or **{"path"}** with
    **-l** and **{"path","column","count"}** with **\--count**. Bytes that
    aren't UTF-8 are given base64-encoded, as **value_base64**.

**\--color** *when*
:   **auto** (the default: on a terminal), **always** or **never**.

## Other

**-j** *n*|**auto**
:   Worker threads. **auto**, the default, is every CPU, or the
    performance cores on Apple silicon.

**-V**, **\--version**
:   Print the version, and the regex engine if it is PCRE2.

**-h**, **\--help**
:   Print a summary of the options.

# TOPICS

**fds help** lists the topics, and **fds help** *topic* prints one:
**search**, **matching**, **many-terms**, **columns**, **output**,
**scripting**, **formats**. They are the pages of the documentation, with
examples and their output.

# EXIT STATUS

**0**
:   Something matched.

**1**
:   Nothing matched.

**2**
:   An error: a file couldn't be read, or strings couldn't be searched,
    even if something matched elsewhere.

# ENVIRONMENT

**NO_COLOR**
:   If set, no colors with **\--color auto**.

# EXAMPLES

Every match of a term under a directory:

    fds data/ 'host-4242.example'

One column, with the values; any case, whole words:

    fds --content -c user.name -i -w data/events.arrow needle

A regex, with matches counted per column:

    fds -E --count data/ '^/api/v[0-9]+/checkout/\d+$'

The files that hold any of 10,000 terms:

    fds -l -f questions.txt train/

JSON Lines, for **jq** or pandas:

    fds --json data/ needle | jq .row

# SEE ALSO

**grep**(1), **rg**(1)

The documentation: **fds help**, *docs/README.md* in the repository, and
<https://felipecruz.github.io/fds/>
