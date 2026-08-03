#!/usr/bin/env bash
# The headless durability/concurrency slice the CI demo job runs against a
# already-booted server (see boot_server.sh). One list, so the Puma and Falcon
# runs exercise exactly the same scenarios — no drift between modes.
#
# These drive the yrby native extension through the full ActionCable /
# yrby-rails / store path: record-before-distribute, exactly-once
# under contention, reliable retransmit, and a fuzz barrage. Running the same
# slice under Falcon proves the extension holds up inside the fiber scheduler.
#
#   PORT=3777 ./e2e_suite.sh
set -euo pipefail

PORT="${PORT:-3777}"
cd "$(dirname "$0")"

# Each script gets its own deadline (coreutils timeout; absent on stock
# macOS, where we run unbounded). A wedged script then fails loudly with
# partial output naming itself, instead of hanging the whole suite — the
# Aug 2026 CI wedge produced six-hour silent hangs with no culprit named.
DEADLINE=""
command -v timeout >/dev/null && DEADLINE="timeout 300"

for t in audit_scenarios audit reliable reliable_provider reliable_stress chaos; do
  echo "--- $t.mjs (PORT=$PORT) ---"
  PORT="$PORT" $DEADLINE bun "$t.mjs"
done
