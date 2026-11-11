# frozen_string_literal: true

# Per-call cost of the binding on hot paths, magnus build vs the spike's C
# build. Run each build in its own process:
#   bundle exec ruby bench/no_magnus/call_overhead.rb
#   YRBY_NATIVE=c bundle exec ruby bench/no_magnus/call_overhead.rb
# Prints which binary loaded, then ns/op (best of ROUNDS) per case and RSS.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
require "digest"

ROUNDS = Integer(ENV.fetch("ROUNDS", 7))

loaded = $LOADED_FEATURES.grep(%r{/yrby(_c)?\.(bundle|so)\z}).first
abort "no yrby binary loaded" unless loaded
puts "binary: #{loaded}"
puts "size: #{File.size(loaded)} sha256: #{Digest::SHA256.file(loaded).hexdigest[0, 12]}"

def rss_kb = Integer(`ps -o rss= -p #{Process.pid}`.strip)

def bench(name, ops)
  best = Float::INFINITY
  ROUNDS.times do
    state = yield(:setup)
    GC.start
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    yield(state)
    best = [best, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0].min
  end
  printf("%-38s %10.1f ns/op\n", name, best.to_f / ops)
end

# Fixtures: 20k one-character updates, each what Doc#edit returns.
source = Y::Doc.new(1)
text = source.get_text("t")
updates = Array.new(20_000) { source.edit { text << "x" } }
full = source.encode_state_as_update
frame = Y.wrap_update(updates.first)
small = Y::Doc.new(2)
small.get_text("t") << ("y" * 1_000)

n = 1_000_000
bench("client_id (GVL held)", n) { |s| s == :setup ? small : n.times { s.client_id } }

n = 200_000
bench("Y.message_kind (GVL released)", n) { |s| s == :setup ? frame : n.times { Y.message_kind(s) } }
bench("encode_state_vector", n) { |s| s == :setup ? small : n.times { s.encode_state_vector } }

n = 100_000
bench("read_text (1k chars)", n) { |s| s == :setup ? small : n.times { s.read_text("t") } }

n = updates.size
bench("apply_update, 20k one-char updates", n) do |s|
  s == :setup ? Y::Doc.new(3) : updates.each { |u| s.apply_update(u) }
end
bench("Text#<< one char, 20k times", n) do |s|
  s == :setup ? Y::Doc.new(4).get_text("t") : n.times { s << "x" }
end
bench("Doc#edit { Text#<< }, 20k times", n) do |s|
  if s == :setup
    d = Y::Doc.new(5)
    [d, d.get_text("t")]
  else
    d, t = s
    n.times { d.edit { t << "x" } }
  end
end

n = 1_000
bench("apply full 20k-char state", n) { |s| s == :setup ? nil : n.times { Y::Doc.new.apply_update(full) } }

GC.start
before = rss_kb
docs = Array.new(10_000) do |i|
  d = Y::Doc.new(i + 10)
  d.get_text("t") << "hello"
  d
end
GC.start
printf("%-38s %10d KB (%d docs)\n", "RSS growth, 10k docs with text", rss_kb - before, docs.size)
printf("%-38s %10d KB\n", "RSS at end", rss_kb)
