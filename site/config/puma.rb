# Puma serves pages and the AnyCable HTTP RPC endpoint. It never sees a
# WebSocket: the anycable-go embedded in thrust terminates those and calls back
# in over RPC, so a Puma thread only ever handles a short request.
#
# ONE worker, always. The document store is a Hash in this process's memory
# (app/lib/room_store.rb), so a second worker would serve different rooms under
# the same URL. This app scales up, not out, by construction — see README.md.
concurrency = Integer(ENV.fetch("WEB_CONCURRENCY", 1))
unless concurrency == 1
  raise "WEB_CONCURRENCY must be 1: the document store and the throttle counters " \
        "are process-local (see site/README.md)"
end
workers concurrency

# Threads are how this app gets concurrency, and every one of them shares the
# one store. That is why RoomStore, ConnectionLimiter, and the token buckets all
# hold explicit mutexes rather than relying on being single-threaded.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)
plugin :tmp_restart
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
