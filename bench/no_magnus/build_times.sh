#!/bin/sh
# Clean and incremental build times for three builds of yrby's extension:
#   magnus  the real extension (ext/yrby, everything)
#   mslice  the same extension cut to the spike's slice (make_magnus_slice.rb)
#   c       the spike's C-ABI build of that slice (ext/yrby_c)
# Same machine, same yrs, same cargo profile; registry pre-fetched.
# Usage: bench/no_magnus/build_times.sh [reps]   (prints TSV)
# Env: PROFILES="default lto"  JOBS="0 2" (0 = cargo's default)
set -e
reps=${1:-2}
PROFILES=${PROFILES:-"default lto"}
JOBS=${JOBS:-"0 2"}
root=$(pwd)
arch=$(ruby -e 'print RbConfig::CONFIG["arch"]')
ruby bench/no_magnus/make_magnus_slice.rb >/dev/null

wall() { /usr/bin/time -p "$@" 2>&1 >/dev/null | awk '/^real/{print $2}'; }
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$profile" "$jobs" "$2" "$3"; }

for profile in $PROFILES; do
  if [ "$profile" = lto ]; then export CARGO_PROFILE_RELEASE_LTO=fat; else unset CARGO_PROFILE_RELEASE_LTO; fi
  for jobs in $JOBS; do
    if [ "$jobs" = 0 ]; then unset CARGO_BUILD_JOBS; else export CARGO_BUILD_JOBS=$jobs; fi
    i=0
    while [ $i -lt "$reps" ]; do
      rm -rf "$root/target/release" "$root/tmp/$arch" "$root/lib/y/yrby.bundle"
      row magnus clean "$(wall bench/no_magnus/magnus_wrap)"
      touch ext/yrby/src/lib.rs
      row magnus "touch lib.rs" "$(wall bench/no_magnus/magnus_wrap)"

      rm -rf "$root/tmp/magnus_slice/build/target" "$root/tmp/magnus_slice/build/yrby.bundle"
      row mslice clean "$(wall bench/no_magnus/mslice_wrap)"
      touch tmp/magnus_slice/src/lib.rs
      row mslice "touch lib.rs" "$(wall bench/no_magnus/mslice_wrap)"

      rm -rf "$root/target/yrby_c" "$root/tmp/yrby_c" "$root/lib/y/yrby_c.bundle"
      row c clean "$(wall bench/no_magnus/cbuild_wrap)"
      touch ext/yrby_c/ffi/src/lib.rs
      row c "touch ffi/lib.rs" "$(wall bench/no_magnus/cbuild_wrap)"
      touch ext/yrby_c/yrby_c.c
      row c "touch yrby_c.c" "$(wall bench/no_magnus/cbuild_wrap)"
      i=$((i + 1))
    done
  done
done
