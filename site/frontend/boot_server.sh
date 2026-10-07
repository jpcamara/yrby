#!/usr/bin/env bash
# Boots the site the same way production does: `thrust bin/serve`.
#
#   PORT=3888 SERVER_PIDFILE=/tmp/site.pid ./boot_server.sh
#
# thrust comes from anycable-thruster, which is Thruster with anycable-go
# embedded in the proxy. One command starts the proxy on $PORT, the embedded
# AnyCable server handling /cable, and Falcon on $TARGET_PORT behind it.
# bin/serve turns the PORT that thrust passes to its upstream into Falcon's
# --bind. The Go server calls Rails over HTTP RPC at /_anycable, and that's the
# only connection between them.
#
# bin/serve runs one Falcon worker unless FALCON_COUNT says otherwise. See
# "Why one process by default" in site/README.md.
#
# Runs the server in the background, waits until it's healthy, and writes the
# thrust pid to $SERVER_PIDFILE so the caller can stop it.
set -euo pipefail

PORT="${PORT:-3888}"
TARGET_PORT="${TARGET_PORT:-$((PORT + 1))}"
PIDFILE="${SERVER_PIDFILE:-/tmp/site-e2e.pid}"
LOG="${SERVER_LOG:-/tmp/site-e2e.log}"

cd "$(dirname "$0")/.." # site/
rm -f "$PIDFILE"

# macOS won't allow a fork after certain Objective-C runtime setup, and Falcon
# forks its worker from the controller process. Without this the worker dies at
# boot and every request gets a connection reset. Linux doesn't need it.
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

export HTTP_PORT="$PORT"
export TARGET_PORT

# One secret configures both halves. Ruby and Go each derive the HTTP RPC key
# and the broadcast key from it.
export ANYCABLE_SECRET="${ANYCABLE_SECRET:-yrby-site-development-secret}"

# The embedded Go server calls Rails at the mounted RPC path over localhost.
# There's one node, so no Redis.
export ANYCABLE_RPC_HOST="http://localhost:${TARGET_PORT}/_anycable"
# Rails sends broadcasts to the Go server over localhost. Two details matter:
#
#   * The broadcast endpoint needs its own port. With a secret configured,
#     anycable-go otherwise mounts /_broadcast on the main port, which breaks
#     thrust's proxy routing, and every page gets a 404 from Go.
#   * config/anycable.yml tells Rails which port to use. Setting
#     ANYCABLE_HTTP_BROADCAST_URL would not work, because both halves read
#     ANYCABLE_ variables and the Go server would bind to that URL itself.
export ANYCABLE_BROADCAST_ADAPTER=http
export ANYCABLE_HTTP_BROADCAST_PORT="${ANYCABLE_HTTP_BROADCAST_PORT:-8090}"

# Layer 0 of the throttles: Go refuses an oversized frame at the socket, so it
# never becomes an RPC call. This limits the whole encoded message, so it's
# higher than Limits::MAX_FRAME_BYTES, the cap on the decoded update. A max-size
# update is about 4/3 larger in base64, plus the JSON envelope, and Go would
# refuse it if this matched the decoded cap. 196608 = Limits::MAX_MESSAGE_BYTES.
export ANYCABLE_MAX_MESSAGE_SIZE="${ANYCABLE_MAX_MESSAGE_SIZE:-196608}"

# Hard ceiling on concurrent sockets, enforced by anycable-go, which holds them.
# The Ruby ConnectionLimiter adds a per-IP cap and a soft process cap in front
# of this one. If Ruby's slot counts ever get out of sync, this still keeps the
# real socket count within the machine's budget. Same number as
# Limits::MAX_CONNECTIONS.
export ANYCABLE_MAX_CONN="${ANYCABLE_MAX_CONN:-500}"

# Forward the client address and the Origin to the RPC calls. The per-IP
# connection cap needs the visitor's address. The Rails origin check only runs
# when HTTP_ORIGIN is in the connect env, because anycable-rails treats a
# missing Origin as allowed. Without this header, Rails couldn't back up
# anycable-go's origin check.
export ANYCABLE_HEADERS="${ANYCABLE_HEADERS:-cookie,x-forwarded-for,origin}"

# The same request body cap as the Dockerfile. Every public route is a GET. The
# RPC and broadcast paths connect to their ports directly and never go through
# thrust's public handler.
export MAX_REQUEST_BODY="${MAX_REQUEST_BODY:-65536}"

# Allowed WebSocket origins for both halves of the cable, from one value. Rails
# reads ALLOWED_ORIGINS itself (config/application.rb). The embedded anycable-go
# wants only host[:port], so strip the scheme here. If ALLOWED_ORIGINS is unset,
# any origin is allowed, which is what local dev, the e2e, and a LAN box want.
if [ -n "${ALLOWED_ORIGINS:-}" ]; then
  export ANYCABLE_ALLOWED_ORIGINS="${ANYCABLE_ALLOWED_ORIGINS:-$(printf '%s' "$ALLOWED_ORIGINS" | sed 's#https\{0,1\}://##g')}"
fi

# Create or migrate the SQLite database before the stack boots.
bin/rails db:prepare >> "$LOG" 2>&1

bundle exec thrust bin/serve > "$LOG" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 60); do
  page=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/up" || true)
  # Healthy means the cable is up too. A bare upgrade request gets the AnyCable
  # welcome, which only arrives after the Connect RPC has reached Rails and come
  # back. The probe sends a loopback Origin because anycable-go returns 403 for
  # a blank Origin when ALLOWED_ORIGINS is set. So if you set ALLOWED_ORIGINS,
  # include this host in it.
  cable=$(curl -s --max-time 3 -N \
    -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Origin: http://127.0.0.1:$PORT" \
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
