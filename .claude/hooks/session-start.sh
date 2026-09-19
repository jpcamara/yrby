#!/bin/bash
# Provisions a Claude Code on the web container so the full demo stack — and in
# particular the real-browser e2e specs under
# examples/actioncable-demo/frontend — can actually run.
#
# The base image ships Ruby 3.3, but both gemspecs require >= 3.4, so nothing
# bundles until a 3.4 is built. It also leaves Postgres and Redis installed but
# stopped, and has no `google-chrome` on PATH (the specs' default), though a
# Playwright Chromium is present.
#
# Idempotent: every step is a no-op once the container state is cached.
set -euo pipefail

# Local checkouts provision themselves; this is only for the web containers.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEMO="$ROOT/examples/actioncable-demo"
RUBY_VERSION="$(sed "s/^ruby-//" "$DEMO/.ruby-version" | tr -d "[:space:]")"

log() { echo "session-start: $*"; }

# --- Ruby ------------------------------------------------------------------
# rbenv + ruby-build ship in the image; the pinned 3.4.x does not. This is the
# slow step (a source build) on a cold container and a no-op on a warm one.
export RBENV_ROOT="${RBENV_ROOT:-/opt/rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if ! rbenv versions --bare | grep -qx "$RUBY_VERSION"; then
  log "building Ruby $RUBY_VERSION (several minutes, cached afterwards)"
  RUBY_CONFIGURE_OPTS="--disable-install-doc" rbenv install -s "$RUBY_VERSION"
fi
rbenv global "$RUBY_VERSION"
rbenv rehash
log "ruby $(ruby -v)"

# --- Services --------------------------------------------------------------
# Installed but not running, and the demo's database.yml defaults to the /tmp
# socket with $USER as the role — neither matches a root container.
pg_isready -q || pg_ctlcluster "$(ls /etc/postgresql | sort -V | tail -1)" main start
until pg_isready -q; do sleep 1; done
su postgres -c "psql -tAc \"select 1 from pg_roles where rolname='$(whoami)'\"" | grep -q 1 \
  || su postgres -c "createuser -s $(whoami)"
redis-cli ping >/dev/null 2>&1 || redis-server --daemonize yes
log "postgres + redis up"

# --- Rust ------------------------------------------------------------------
# yrs, the CRDT crate the extension wraps, uses if-let guards — stable since
# 1.95, and the image pins an older stable, so the build fails on E0658 until
# the toolchain moves. CI pulls `stable` for the same reason.
if ! rustc --version | awk '{split($2, v, "."); exit !(v[1] > 1 || (v[1] == 1 && v[2] >= 95))}'; then
  log "updating rust stable (image ships $(rustc --version | cut -d' ' -f2))"
  rustup update stable
fi
log "rust $(rustc --version)"

# --- Gem + native extension ------------------------------------------------
cd "$ROOT"
bundle install
bundle exec rake compile
log "native extension compiled"

# --- Demo app --------------------------------------------------------------
cd "$DEMO"
export PGHOST=/var/run/postgresql
export PGUSER="$(whoami)"
bundle install
bin/rails db:prepare
log "demo app ready"

# --- JavaScript ------------------------------------------------------------
# The frontend resolves yrby-client from the built package, so order matters.
cd "$ROOT/packages/client"
npm install
npm run build
cd "$DEMO/frontend"
bun install
bun run build
log "frontend bundle built"

# --- Session environment ---------------------------------------------------
# The browser specs shell out to agent-browser, which looks for Chrome on PATH
# unless told otherwise; the image only has the Playwright build.
CHROME="$(ls -d /opt/pw-browsers/chromium-*/chrome-linux/chrome 2>/dev/null | sort -V | tail -1 || true)"
{
  echo "export PGHOST=/var/run/postgresql"
  echo "export PGUSER=$(whoami)"
  echo "export REDIS_URL=redis://localhost:6379/15"
  [ -n "$CHROME" ] && echo "export AGENT_BROWSER_EXECUTABLE_PATH=$CHROME"
} >> "${CLAUDE_ENV_FILE:-/dev/null}"

log "ready — boot with: cd examples/actioncable-demo && SERVER=puma WORKERS=2 CABLE_ADAPTER=redis PORT=3777 frontend/boot_server.sh"
