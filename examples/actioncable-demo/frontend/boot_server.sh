#!/usr/bin/env bash
# Boots the demo server for the e2e suite under either Puma (default, threaded)
# or Falcon (fiber scheduler). The harnesses are server-agnostic — they only
# need the app on $PORT — so flipping SERVER is how we prove the native
# extension behaves the same inside Ruby's fiber scheduler as it does under
# Puma's thread pool.
#
#   SERVER=falcon PORT=3777 PIDFILE=/tmp/srv.pid ./boot_server.sh
#
# Backgrounds the server, waits until it is healthy, and writes its pid to
# $PIDFILE so the caller can tear it down.
set -euo pipefail

SERVER="${SERVER:-puma}"
PORT="${PORT:-3777}"
# Deliberately NOT named PIDFILE: config/puma.rb reads ENV["PIDFILE"] and would
# then manage this file itself, racing the pid we capture below.
PIDFILE="${SERVER_PIDFILE:-/tmp/e2e-server.pid}"
LOG="${SERVER_LOG:-/tmp/e2e-server.log}"

cd "$(dirname "$0")/.." # examples/actioncable-demo
rm -f "$PIDFILE" # clear any stale pid from a prior run

case "$SERVER" in
  puma)
    bin/rails s -p "$PORT" > "$LOG" 2>&1 &
    ;;
  falcon)
    # --count 1 keeps the in-process document registry to a single process,
    # matching the async cable adapter the e2e suite assumes. Plain http (not
    # falcon's default https) so the ws:// harness connects. Killing the
    # controller pid tears down its forked worker.
    bundle exec falcon serve --bind "http://localhost:$PORT" --count 1 > "$LOG" 2>&1 &
    ;;
  *)
    echo "boot_server.sh: unknown SERVER=$SERVER (want puma|falcon)" >&2
    exit 1
    ;;
esac

# Record the launcher pid ourselves rather than trusting each server's own
# pidfile handling (Puma rewrites/removes it, Falcon doesn't write one). SIGTERM
# to this pid stops the server — and Falcon's forked worker — cleanly.
echo $! > "$PIDFILE"

for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/docs/demo")" = "200" ]; then
    echo "boot_server.sh: $SERVER healthy on $PORT (pid $(cat "$PIDFILE"))"
    exit 0
  fi
  sleep 1
done

echo "boot_server.sh: $SERVER did not become healthy on $PORT" >&2
cat "$LOG" >&2 || true
exit 1
