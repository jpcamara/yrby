#!/usr/bin/env bash
# The Rails <-> Loco storage interop test (tests/rails_interop.rs), in every
# combination of database, schema owner, and key-derivation digest. Needs
# Docker. Builds the Rails-side image, starts a throwaway Postgres unless
# YRBY_INTEROP_PG_URL points at one, and stops it afterwards.
#
#   crates/loco-yrby/interop/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
crates="$(cd "$here/../.." && pwd)"

docker build -q -t yrby-interop "$here" > /dev/null

pg=""
if [ -z "${YRBY_INTEROP_PG_URL:-}" ]; then
  pg="yrby-interop-pg-$$"
  # Published on all interfaces: on Linux, containers reach the host through
  # the bridge, not loopback.
  docker run -d --rm --name "$pg" -e POSTGRES_USER=yrby -e POSTGRES_PASSWORD=yrby \
    -p 55433:5432 postgres:17 > /dev/null
  trap 'docker stop "$pg" > /dev/null' EXIT
  until docker exec "$pg" psql -U yrby -d postgres -c 'select 1' > /dev/null 2>&1; do sleep 1; done
  export YRBY_INTEROP_PG_URL="postgres://yrby:yrby@127.0.0.1:55433"
fi

cd "$crates"
cargo build -q -p loco-yrby --tests
for db in sqlite postgres; do
  for schema in rails loco; do
    for digest in SHA256 SHA1; do
      echo "== $db, $schema schema, $digest"
      YRBY_INTEROP_DB=$db YRBY_INTEROP_SCHEMA=$schema YRBY_INTEROP_DIGEST=$digest \
        cargo test -q -p loco-yrby --test rails_interop -- --ignored
    done
  done
done
