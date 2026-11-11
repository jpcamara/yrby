#!/bin/sh
# Run each test file on its own and print "file runs failures errors skips".
# YRBY_NATIVE=c picks the spike's C build; unset, the magnus build.
# Usage: bench/no_magnus/run_tests.sh OUTDIR [files...]
out=$1; shift
mkdir -p "$out"
files=${*:-$(ls test/*_test.rb)}
for f in $files; do
  name=$(basename "$f" .rb)
  bundle exec ruby -Ilib -Itest "$f" > "$out/$name.log" 2>&1
  summary=$(grep -E '^[0-9]+ runs,' "$out/$name.log" | tail -1)
  if [ -z "$summary" ]; then summary="LOAD FAILURE"; fi
  echo "$name: $summary"
done
