#!/usr/bin/env bash
# Boots the site the way it is deployed: `thrust bin/serve`.
#
#   PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
#
# thrust is anycable-thruster — Thruster with anycable-go embedded in the proxy.
# One command gets you the proxy on $PORT, the embedded AnyCable server owning
# /cable, and Falcon on $TARGET_PORT behind it (bin/serve translates the PORT
# thrust hands its upstream into Falcon's --bind). The Go server calls back into
# Rails over HTTP RPC at /_anycable; nothing else connects the two.
#
# ONE Falcon worker, always — bin/serve enforces it: the document store is a
# Hash in that process's memory. See site/README.md.
#
# Backgrounds the whole thing, waits until it is healthy, and writes the thrust
# pid to $SERVER_PIDFILE so the caller can tear it down.
set -euo pipefail

PORT="${PORT:-3888}"
TARGET_PORT="${TARGET_PORT:-$((PORT + 1))}"
PIDFILE="${SERVER_PIDFILE:-/tmp/site-e2e.pid}"
LOG="${SERVER_LOG:-/tmp/site-e2e.log}"

cd "$(dirname "$0")/.." # site/
rm -f "$PIDFILE"

# macOS refuses to fork after certain Objective-C runtime initialization, and
# Falcon forks its worker from the controller process. Without this the worker
# dies at boot and every request comes back as a connection reset. Not a yrby
# problem, and not needed on Linux.
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

export HTTP_PORT="$PORT"
export TARGET_PORT

# One secret configures both halves: AnyCable derives the HTTP RPC key and the
# broadcast key from it on the Ruby side and the Go side alike.
export ANYCABLE_SECRET="${ANYCABLE_SECRET:-yrby-site-development-secret}"

# The embedded Go server reaches Rails at the mounted RPC path over localhost,
# and Rails hands broadcasts back to it the same way. No Redis in either
# direction — there is one node.
export ANYCABLE_RPC_HOST="http://localhost:${TARGET_PORT}/_anycable"
# Rails hands broadcasts to the Go server over localhost. Two things about this
# are load-bearing:
#
#   * The broadcast endpoint gets its OWN port. With a secret configured,
#     anycable-go otherwise mounts /_broadcast on the main port, and mounting it
#     there displaces thrust's proxy routing — every page then 404s from Go.
#   * Rails is pointed at that port from config/anycable.yml, not from
#     ANYCABLE_HTTP_BROADCAST_URL, because both halves read the ANYCABLE_ prefix
#     and the Go server would take the URL as its own bind address.
export ANYCABLE_BROADCAST_ADAPTER=http
export ANYCABLE_HTTP_BROADCAST_PORT="${ANYCABLE_HTTP_BROADCAST_PORT:-8090}"

# Layer 0 of the throttle stack: an over-size frame is refused at the socket and
# never becomes an RPC call. Same number as Limits::MAX_FRAME_BYTES.
export ANYCABLE_MAX_MESSAGE_SIZE="${ANYCABLE_MAX_MESSAGE_SIZE:-131072}"

# Forward the client address to the RPC calls, so the per-IP connection cap sees
# the visitor rather than the proxy.
export ANYCABLE_HEADERS="${ANYCABLE_HEADERS:-cookie,x-forwarded-for}"

bundle exec thrust bin/serve > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 60); do
  page=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/up" || true)
  # Healthy means the cable is up too: a bare upgrade gets the AnyCable
  # welcome, which only arrives once the Connect RPC has round-tripped to Rails.
  cable=$(curl -s --max-time 3 -N \
    -H "Connection: Upgrade" -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "http://127.0.0.1:$PORT/cable" 2>/dev/null | head -c 200 || true)
  if [ "$page" = "200" ] && [[ "$cable" == *welcome* ]]; then
    echo "boot_server.sh: healthy on $PORT (thrust pid $(cat "$PIDFILE"), falcon :$TARGET_PORT)"
    exit 0
  fi
  sleep 1
done

echo "boot_server.sh: the site did not become healthy on $PORT (page=$page)" >&2
tail -40 "$LOG" >&2 || true
exit 1
