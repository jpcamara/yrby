#!/bin/sh
# Binary sizes of the three builds (see build_times.sh), as built and after
# `strip -x` (what a precompiled gem would ship). Also whether dyld on this
# Mac will load each one (LC_SYMTAB stroff 8-aligned; see docs/no-magnus.md).
# Run after building all three with the profile you want to measure.
for f in lib/y/yrby.bundle tmp/magnus_slice/build/yrby.bundle lib/y/yrby_c.bundle; do
  [ -f "$f" ] || { echo "missing $f"; continue; }
  tmp=$(mktemp)
  cp "$f" "$tmp" && strip -x "$tmp" 2>/dev/null
  stroff=$(otool -l "$f" | awk '/LC_SYMTAB/{s=1} s&&/stroff/{print $2; exit}')
  printf '%-40s %9d bytes  stripped %9d  loads:%s\n' "$f" "$(stat -f %z "$f")" "$(stat -f %z "$tmp")" "$([ $((stroff % 8)) = 0 ] && echo yes || echo no)"
  rm -f "$tmp"
done
