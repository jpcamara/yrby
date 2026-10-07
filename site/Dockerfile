# Multi-stage build for the yrby site.
#
#   docker build -t yrby-site .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=$(openssl rand -hex 64) yrby-site
#
# Three stages: gems, then the bun bundles, then a runtime image with neither
# toolchain. The final image is Ruby slim plus the gems and the built assets.
# It has no Rust (yrby publishes precompiled platform gems), no Node, and no bun.
ARG RUBY_VERSION=3.4.5

# --- gems ---------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS gems
WORKDIR /rails

# build-essential is for any gem that needs a C toolchain. yrby and
# commonmarker both resolve to precompiled platform gems, so this build
# compiles no Rust.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# --- demo bundles + stylesheet ------------------------------------------------
FROM docker.io/oven/bun:1 AS assets
WORKDIR /build
COPY frontend/package.json frontend/bun.lock frontend/bunfig.toml ./frontend/
RUN cd frontend && bun install --frozen-lockfile
COPY frontend ./frontend
# Tailwind scans the ERB templates for class names (@source in css/site.css),
# so this stage needs the app's views too.
COPY app ./app
RUN cd frontend && bun run build

# --- runtime ------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim
WORKDIR /rails

# curl is for the health check. The build toolchain stays out of this image.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# thrust listens on HTTP_PORT and proxies to Falcon on TARGET_PORT. thrust sets
# PORT to TARGET_PORT for its upstream, and bin/serve turns that into Falcon's
# --bind. The anycable-go embedded in thrust answers /cable itself and never
# proxies it.
ENV HTTP_PORT="3000" TARGET_PORT="3001"

# The embedded Go server calls Rails at the mounted RPC path over localhost.
ENV ANYCABLE_RPC_HOST="http://localhost:3001/_anycable"

# No Redis. There's one node, so Rails posts broadcasts straight to the Go
# server. The broadcast endpoint needs its own port. With a secret configured,
# anycable-go otherwise mounts /_broadcast on the main port, which breaks
# thrust's proxy routing.
ENV ANYCABLE_BROADCAST_ADAPTER="http" ANYCABLE_HTTP_BROADCAST_PORT="8090"

# Layer 0 of the throttles: Go refuses an oversized frame at the socket, so it
# never becomes an RPC call. This limits the whole encoded message, so it's
# higher than Limits::MAX_FRAME_BYTES, the cap on the decoded update. A
# max-size update is about 4/3 larger in base64, plus the JSON envelope, and
# Go would refuse it if this matched the decoded cap.
# 196608 = Limits::MAX_MESSAGE_BYTES.
ENV ANYCABLE_MAX_MESSAGE_SIZE="196608"

# Hard ceiling on concurrent sockets, enforced by anycable-go, which holds them.
# The Ruby ConnectionLimiter adds a per-IP cap and a soft process cap in front
# of this one. Same number as Limits::MAX_CONNECTIONS.
ENV ANYCABLE_MAX_CONN="500"

# Forward the client address and the Origin to the RPC calls. The per-IP
# connection cap needs the visitor's address. The Rails origin check needs the
# Origin header, because anycable-rails treats a missing Origin as allowed.
ENV ANYCABLE_HEADERS="cookie,x-forwarded-for,origin"

# Cap request bodies at the proxy. Every public route is a GET, so 64 KB is
# plenty. This doesn't affect AnyCable. The embedded Go server connects to
# Falcon's port directly for RPC (ANYCABLE_RPC_HOST above), and Rails posts
# broadcasts to Go's own 8090 listener. Neither goes through thrust's public
# handler, which is the only place MAX_REQUEST_BODY applies (thruster's
# internal/service.go).
ENV MAX_REQUEST_BODY="65536"

# ANYCABLE_SECRET and SECRET_KEY_BASE are set at runtime. Both halves of
# AnyCable, Ruby and Go, derive the HTTP RPC key and the broadcast key from
# ANYCABLE_SECRET.

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .
# bun builds the demo bundles, fonts, and site.css into public/, and the app
# serves them as plain static files. There's no asset pipeline to run.
COPY --from=assets /build/public /rails/public

# storage/ is where the SQLite volume mounts. The rails user has to own it so
# db:prepare can create the database file on a fresh volume. Mode 700 means
# only the app user can read the database and its room content.
RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp public && \
    chmod 700 storage
USER rails:rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000

# One command runs the proxy, the embedded AnyCable server, and Falcon.
# bin/serve runs one Falcon worker unless FALCON_COUNT says otherwise, because
# the throttle counters live in process memory. See "Why one process by
# default" in README.md.
CMD ["bundle", "exec", "thrust", "./bin/serve"]
