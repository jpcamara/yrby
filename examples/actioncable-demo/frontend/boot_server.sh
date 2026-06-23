#!/usr/bin/env bash
# Boots the demo server for the e2e suite under either Puma (threaded) or Falcon
# (fiber scheduler). The harnesses are server-agnostic — they only need the app
# on $PORT — so flipping SERVER is how we prove the native extension behaves the
# same inside Ruby's fiber scheduler as it does under Puma's thread pool.
#
#   SERVER=falcon PORT=3777 WORKERS=2 SERVER_PIDFILE=/tmp/srv.pid ./boot_server.sh
#
# WORKERS controls the process count (default 2 — a realistic multi-process
# deployment, not a single process). With WORKERS>1 the workers share documents
# only through the cable adapter and the durable store, so the caller MUST set
# CABLE_ADAPTER=redis (the async adapter is in-process); we fail fast otherwise.
#
# Backgrounds the server, waits until it is healthy, and writes its pid to
# $SERVER_PIDFILE so the caller can tear it down.
set -euo pipefail

SERVER="${SERVER:-puma}"
PORT="${PORT:-3777}"
WORKERS="${WORKERS:-2}"
# Deliberately NOT named PIDFILE: config/puma.rb reads ENV["PIDFILE"] and would
# then manage this file itself, racing the pid we capture below.
PIDFILE="${SERVER_PIDFILE:-/tmp/e2e-server.pid}"
LOG="${SERVER_LOG:-/tmp/e2e-server.log}"

if [ "$WORKERS" -gt 1 ] && [ "${CABLE_ADAPTER:-async}" = "async" ]; then
  echo "boot_server.sh: WORKERS=$WORKERS needs CABLE_ADAPTER=redis (async is in-process)" >&2
  exit 1
fi

cd "$(dirname "$0")/.." # examples/actioncable-demo
rm -f "$PIDFILE" # clear any stale pid from a prior run

case "$SERVER" in
  puma)
    # Cluster mode: WEB_CONCURRENCY workers, each with its own thread pool. The
    # port-unique -P keeps Puma off its default tmp/pids/server.pid so two
    # servers booted from the same app dir (the multi-process test) don't
    # collide; teardown still uses the launcher pid captured below.
    WEB_CONCURRENCY="$WORKERS" bin/rails s -p "$PORT" -P "tmp/pids/e2e-$PORT.pid" > "$LOG" 2>&1 &
    ;;
  falcon)
    # --count forks that many worker processes, each running its own fiber
    # reactor. Plain http (not falcon's default https) so the ws:// harness
    # connects. Killing the controller pid tears down every forked worker.
    bundle exec falcon serve --bind "http://localhost:$PORT" --count "$WORKERS" > "$LOG" 2>&1 &
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
    echo "boot_server.sh: $SERVER healthy on $PORT, $WORKERS worker(s) (pid $(cat "$PIDFILE"))"
    exit 0
  fi
  sleep 1
done

echo "boot_server.sh: $SERVER did not become healthy on $PORT" >&2
cat "$LOG" >&2 || true
exit 1
