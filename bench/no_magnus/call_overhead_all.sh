#!/bin/sh
# call_overhead.rb against the three builds, each in its own process.
# Build all three with the same profile first (build_times.sh leaves them so).
echo "== magnus (full)"; bundle exec ruby bench/no_magnus/call_overhead.rb
echo "== magnus (slice)"; YRBY_NATIVE_PATH=tmp/magnus_slice/build/yrby.bundle bundle exec ruby bench/no_magnus/call_overhead.rb
echo "== c (slice)"; YRBY_NATIVE=c bundle exec ruby bench/no_magnus/call_overhead.rb
