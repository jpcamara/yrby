# frozen_string_literal: true

# Torture test: sustained parallel contention on shared native objects.
#
# With the GVL released, writer threads genuinely contend on the doc's
# internal RwLock in parallel. This hammers that path for DURATION seconds
# and asserts CRDT convergence afterward. Run with a larger thread count
# than cores to also exercise queueing under oversubscription.
#
#   bundle exec ruby bench/torture.rb
#   DURATION=60 THREADS=32 bundle exec ruby bench/torture.rb

require "yrb_lite"
require "yrb_lite/sync"
require "json"

DURATION = Float(ENV.fetch("DURATION", 30))
THREADS = Integer(ENV.fetch("THREADS", 16))

# Source material: a pile of distinct updates to apply repeatedly, plus a
# large ProseMirror update for heavyweight reads if the bench fixture exists.
fixture = File.expand_path("large_update.bin", __dir__)
LARGE_UPDATE = File.exist?(fixture) ? File.binread(fixture) : nil

docs = Array.new(4) { YrbLite::Doc.new }
UPDATES = docs.map(&:encode_state_as_update) # empty-but-distinct baselines

# Build real content updates from Y docs via the sync protocol fixtures used
# in tests: simplest is to reuse the large update split across appliers, but
# raw updates from different "clients" gives the CRDT real merge work. We
# fabricate them by round-tripping through docs seeded from the large update.
SOURCE_UPDATES =
  if LARGE_UPDATE
    seed = YrbLite::Doc.new
    seed.apply_update(LARGE_UPDATE)
    sv = YrbLite::Doc.new.encode_state_vector
    [seed.encode_state_as_update(sv), LARGE_UPDATE]
  else
    UPDATES
  end

shared = YrbLite::Awareness.new
# Seed all source content up front so readers never observe an empty doc;
# writers then hammer idempotent re-application (still a real write lock).
SOURCE_UPDATES.each { |u| shared.apply_update(u) }
stop = false
ops = Hash.new(0)
ops_mutex = Mutex.new
errors = Queue.new

puts "torture: #{THREADS} threads, #{DURATION}s, large fixture: #{LARGE_UPDATE ? "yes (#{LARGE_UPDATE.bytesize} bytes)" : 'no'}"

threads = THREADS.times.map do |i|
  Thread.new do
    local = Hash.new(0)
    rng = Random.new(i)
    until stop
      case rng.rand(6)
      when 0 # writer: apply a full update (write lock, idempotent re-apply)
        shared.apply_update(SOURCE_UPDATES[rng.rand(SOURCE_UPDATES.length)])
        local[:apply] += 1
      when 1 # sync handshake against the shared doc (step1 in, step2 out)
        peer = YrbLite::Doc.new
        shared.handle(peer.sync_step1)
        local[:handshake] += 1
      when 2 # reader: encode full state (read lock, big copy)
        shared.encode_state_as_update
        local[:encode] += 1
      when 3 # reader: state vector (read lock, small)
        shared.encode_state_vector
        local[:sv] += 1
      when 4 # awareness churn (DashMap, no doc lock)
        shared.set_local_state(JSON.generate({ "t" => i, "n" => local[:aware] }))
        shared.encode_awareness_update
        local[:aware] += 1
      when 5 # heavyweight read: full state encode from the live doc
        if LARGE_UPDATE
          shared.encode_state_as_update
          local[:extract] += 1
        else
          shared.local_state
          local[:read] += 1
        end
      end
    end
    ops_mutex.synchronize { local.each { |k, v| ops[k] += v } }
  rescue StandardError => e
    errors << "thread #{i}: #{e.class}: #{e.message}"
  end
end

# Also hammer the Sync registry from outside the pool: concurrent creation
# of many keyed documents (the mutex path).
registry_thread = Thread.new do
  n = 0
  until stop
    8.times.map do |j|
      Thread.new { YrbLite::Sync.awareness_for("room-#{n}-#{j % 3}") }
    end.each(&:join)
    n += 1
  end
  ops_mutex.synchronize { ops[:registry_rounds] += n }
rescue StandardError => e
  errors << "registry: #{e.class}: #{e.message}"
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sleep DURATION
stop = true
threads.each(&:join)
registry_thread.join
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

abort("ERRORS:\n#{Array.new(errors.size) { errors.pop }.join("\n")}") unless errors.empty?

# Convergence: the shared doc must equal sequential application.
sequential = YrbLite::Doc.new
SOURCE_UPDATES.each { |u| sequential.apply_update(u) }
unless sequential.encode_state_vector == shared.encode_state_vector &&
       sequential.encode_state_as_update == shared.encode_state_as_update
  abort("CONVERGENCE FAILURE: shared doc diverged from sequential application")
end

total = ops.values.sum
puts format("completed %d ops in %.1fs (%.0f ops/s) with zero errors", total, elapsed, total / elapsed)
ops.sort_by { |_, v| -v }.each { |k, v| puts format("  %-16s %8d", k, v) }
puts "convergence: OK (matches sequential application)"
