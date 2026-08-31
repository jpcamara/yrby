#!/usr/bin/env bash
# Boots the site for the e2e harness.
#
#   PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
#
# Falcon, one process. That is not a test convenience — it is the app's shape.
# The document store is a Hash in process memory and the cable adapter is
# `async`, so a second worker would serve different rooms under the same URL.
#
# Backgrounds the server, waits until it is healthy, and writes its pid to
# $SERVER_PIDFILE so the caller can tear it down.
set -euo pipefail

PORT="${PORT:-3888}"
PIDFILE="${SERVER_PIDFILE:-/tmp/site-e2e.pid}"
LOG="${SERVER_LOG:-/tmp/site-e2e.log}"

cd "$(dirname "$0")/.." # site/
rm -f "$PIDFILE"

# Plain http (not falcon's default https) so the ws:// harness connects.
bundle exec falcon serve --bind "http://127.0.0.1:$PORT" --count 1 > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/up")" = "200" ]; then
    echo "boot_server.sh: healthy on $PORT (pid $(cat "$PIDFILE"))"
    exit 0
  fi
  sleep 1
done

echo "boot_server.sh: the site did not become healthy on $PORT" >&2
cat "$LOG" >&2 || true
exit 1
