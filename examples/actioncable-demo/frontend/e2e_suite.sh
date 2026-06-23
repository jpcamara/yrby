#!/usr/bin/env bash
# The headless durability/concurrency slice the CI demo job runs against a
# already-booted server (see boot_server.sh). Kept as one list so the Puma and
# Falcon runs exercise exactly the same scenarios — no drift between modes.
#
# These drive the yrb-lite native extension through the full ActionCable /
# yrb-lite-actioncable / store path: record-before-distribute, exactly-once
# under contention, reliable retransmit, and a fuzz barrage. Running the same
# slice under Falcon proves the extension holds up inside the fiber scheduler.
#
#   PORT=3777 ./e2e_suite.sh
set -euo pipefail

PORT="${PORT:-3777}"
cd "$(dirname "$0")"

for t in audit_scenarios audit reliable reliable_provider reliable_stress chaos; do
  echo "--- $t.mjs (PORT=$PORT) ---"
  PORT="$PORT" bun "$t.mjs"
done
