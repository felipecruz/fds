#!/bin/sh
# Writes the man page, docs/fds.1, from docs/fds.1.md (needs pandoc).
# Usage: docs/man.sh   (then commit docs/fds.1; `zig build` installs it)
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^const version = "\(.*\)";/\1/p' build.zig)
pandoc --standalone --to man -M footer="fds $version" -M date="" docs/fds.1.md -o docs/fds.1
echo "docs/fds.1: fds $version"
