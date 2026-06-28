# frozen_string_literal: true

# Proves the GVL is released during native CRDT work: with the GVL held,
# N threads take ~Nx serial time; with it released, wall-clock time should
# approach serial time / cores.
#
# Run: bundle exec ruby bench/parallelism_bench.rb

require "y"

UPDATE = File.binread(File.expand_path("large_update.bin", __dir__))
THREADS = Integer(ENV.fetch("THREADS", 8))
OPS_PER_THREAD = Integer(ENV.fetch("OPS", 4))

def time
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

work = lambda do
  OPS_PER_THREAD.times do
    # Parse + apply a large update into a fresh doc, then re-encode its state.
    # It's all heavy native work, and embarrassingly parallel.
    doc = Y::Doc.new
    doc.apply_update(UPDATE)
    doc.encode_state_as_update
  end
end

# Warm up (first call pays any lazy init)
Y::Doc.new.apply_update(UPDATE)

serial = time { THREADS.times { work.call } }
parallel = time { THREADS.times.map { Thread.new(&work) }.each(&:join) }

puts format("update size:    %d bytes", UPDATE.bytesize)
puts format("threads:        %d x %d ops each", THREADS, OPS_PER_THREAD)
puts format("serial:         %.3fs", serial)
puts format("parallel:       %.3fs", parallel)
puts format("speedup:        %.2fx", serial / parallel)
