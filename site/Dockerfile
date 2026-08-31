# Multi-stage build for the yrby site.
#
#   docker build -t yrby-site .
#   docker run -p 3000:3000 -e SECRET_KEY_BASE=$(openssl rand -hex 64) yrby-site
#
# Three stages: gems, then the bun bundle, then a runtime image that carries
# neither toolchain. The final image is Ruby slim plus the gems and the built
# assets — no Rust (yrby ships precompiled platform gems), no Node, no bun.
ARG RUBY_VERSION=3.4.5

# --- gems ---------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS gems
WORKDIR /rails

# build-essential is here for any gem that still needs a C toolchain. yrby and
# commonmarker both resolve to precompiled platform gems, so nothing Rust is
# compiled during this build.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# --- demo bundles -------------------------------------------------------------
FROM docker.io/oven/bun:1 AS assets
WORKDIR /build
COPY frontend/package.json frontend/bun.lock frontend/bunfig.toml ./frontend/
RUN cd frontend && bun install --frozen-lockfile
COPY frontend ./frontend
RUN cd frontend && bun build.mjs

# --- runtime ------------------------------------------------------------------
FROM docker.io/library/ruby:$RUBY_VERSION-slim
WORKDIR /rails

# curl is the health check; the rest of the toolchain does not ship.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .
COPY --from=assets /build/public /rails/public

# Digest the stylesheet at build time so a request never pays for it. No
# database and no secrets are needed for this; the dummy key is discarded.
RUN SECRET_KEY_BASE=dummy bundle exec rails assets:precompile

RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails log tmp public
USER rails:rails

EXPOSE 3000

# Falcon, one worker. The document store is a Hash in this process's memory and
# the cable adapter is `async`, so a second worker would serve different rooms
# under the same URL. See README.md ("Why one process").
CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:3000", "--count", "1"]
