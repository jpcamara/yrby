# Many documents edited at once, Y::Document vs Y::PgDocument. Forked writer
# processes append each document's edits while joiner processes sync new
# clients, each on its own connection. STORE=yrby|pg, needs a Postgres with
# pg_ydoc on :28817 and WORKLOAD_DIR with w<SIZE>.txt.
#
#   DOCS=32 SIZE=50 WRITERS=8 JOINERS=2 MODE=own|shared EDITS=1000
#
# MODE=own gives each document one writer, so its edits arrive in order;
# MODE=shared deals every document's edits across all writers, so they can
# commit out of order, as with several app servers.
require "active_record"
require "pg"
require "tmpdir"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "y"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/pg_document"
require "y/pg_ydoc"
require "active_record/connection_adapters/postgresql_adapter"
Y::PgYdoc.register_type(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)

STORE = ENV.fetch("STORE")
DOCS = Integer(ENV.fetch("DOCS", "32"))
SIZE = Integer(ENV.fetch("SIZE", "50"))
WRITERS = Integer(ENV.fetch("WRITERS", "8"))
JOINERS = Integer(ENV.fetch("JOINERS", "2"))
MODE = ENV.fetch("MODE", "own")
EDITS = Integer(ENV.fetch("EDITS", "1000"))
DB = { adapter: "postgresql", host: "localhost", port: 28_817, database: "postgres", pool: 2,
       gssencmode: "disable" }.freeze # libpq GSS setup crashes forked children on macOS
model = STORE == "pg" ? Y::PgDocument : Y::Document

seed, half_sv, expected, *updates = File.readlines(File.join(ENV.fetch("WORKLOAD_DIR"), "w#{SIZE}.txt"), chomp: true)
                                        .map { |h| [h].pack("H*") }
expected.force_encoding("UTF-8")
updates = updates.first(EDITS)
expected = nil if EDITS < 1000 # the reference text is for the full session
keys = Array.new(DOCS) { |i| "load/#{i}" }

ActiveRecord::Base.establish_connection(DB)
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.verbose = false
conn = ActiveRecord::Base.connection
conn.execute("create extension if not exists pg_ydoc")
conn.execute("drop table if exists y_document_updates, y_documents, y_document_log, y_document_log_slot cascade")
ActiveRecord::Schema.define do
  create_table :y_documents do |t|
    t.string :key, null: false, index: { unique: true }
    t.references :record, polymorphic: true, null: true, index: false
    t.string :name
    t.binary :state
    t.timestamps
  end
  create_table :y_document_updates do |t|
    t.references :document, null: false, foreign_key: { to_table: :y_documents }, index: false
    t.binary :payload, null: false
    t.boolean :pending, null: false, default: false
    t.datetime :created_at, null: false
    t.index %i[document_id pending]
  end
end
if STORE == "pg"
  conn.execute("alter table y_documents alter column state type ydoc using ydoc(state)")
  conn.execute(Y::PgDocument::SCHEMA)
end
keys.each { |k| model.append(k, seed) }
conn.execute("checkpoint")
conn.execute("select pg_stat_reset()")
tables = conn.select_values("select relid::regclass::text from pg_stat_user_tables where relname like 'y\\_document%'")
wal0 = conn.select_value("select pg_current_wal_lsn()::text")
ActiveRecord::Base.connection_pool.disconnect!

now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
out = Dir.mktmpdir

# Work for writer w: [key, update] pairs in the order it sends them.
jobs = Array.new(WRITERS) { [] }
if MODE == "own"
  keys.each_with_index { |k, d| updates.each { |u| jobs[d % WRITERS] << [k, u] } }
else
  keys.each_with_index { |k, d| updates.each_with_index { |u, i| jobs[(d + i) % WRITERS] << [k, u] } }
end
# Interleave each writer's documents so they all advance together.
jobs.map! { |js| js.group_by(&:first).values.then { |gs| gs.first.zip(*gs[1..]).flatten(1).compact } }

stop_file = File.join(out, "stop")
t0 = now.call
writers = jobs.each_with_index.map do |js, w|
  fork do
    ActiveRecord::Base.establish_connection(DB)
    lat = []
    errors = Hash.new(0)
    js.each do |k, u|
      t = now.call
      begin
        model.append(k, u)
      rescue StandardError => e
        errors[e.class.name] += 1
        retry if errors.values.sum < 1000
      end
      lat << (now.call - t)
    end
    File.binwrite(File.join(out, "w#{w}"), Marshal.dump([lat, errors]))
  end
end
joiners = Array.new(JOINERS) do |j|
  fork do
    ActiveRecord::Base.establish_connection(DB)
    rng = Random.new(j)
    lat = []
    raise "state vector too long for a one-byte length" if half_sv.bytesize > 127

    step1 = "\x00\x00".b + half_sv.bytesize.chr + half_sv
    until File.exist?(stop_file)
      k = keys.sample(random: rng)
      t = now.call
      if STORE == "pg"
        doc = model.select(:id).find_by(key: k)
        doc.sync_state
        doc.sync_diff(half_sv)
      else
        d = Y::Doc.new
        d.apply_update(model.load_state(k))
        d.sync_step1
        d2 = Y::Doc.new
        d2.apply_update(model.load_state(k))
        d2.handle_sync_message(step1)
      end
      lat << (now.call - t)
    end
    File.binwrite(File.join(out, "j#{j}"), Marshal.dump(lat))
  end
end
writers.each { |pid| Process.wait(pid) }
wall = now.call - t0
File.write(stop_file, "")
joiners.each { |pid| Process.wait(pid) }

pct = ->(xs, p) { xs.empty? ? 0 : xs.sort[(xs.size * p).floor.clamp(0, xs.size - 1)] * 1000 }
wl = []
errors = Hash.new(0)
WRITERS.times do |w|
  l, e = Marshal.load(File.binread(File.join(out, "w#{w}")))
  wl.concat(l)
  e.each { |k, v| errors[k] += v }
end
jl = Array.new(JOINERS) { |j| Marshal.load(File.binread(File.join(out, "j#{j}"))) }.flatten

ActiveRecord::Base.establish_connection(DB)
conn = ActiveRecord::Base.connection
wal = conn.select_value("select pg_wal_lsn_diff(pg_current_wal_lsn(), '#{wal0}')").to_f
sleep 0.6 # let the stats collector catch up
stats = conn.select_rows(<<~SQL)
  select coalesce(sum(n_dead_tup), 0), coalesce(sum(n_tup_upd + n_tup_del), 0),
         coalesce(sum(autovacuum_count), 0)
  from pg_stat_user_tables where relname like 'y\\_document%'
SQL
dead, churn, autovac = stats.first.map(&:to_i)
size = tables.sum { |t| conn.select_value("select pg_total_relation_size('#{t}')").to_i }

text_of = lambda { |parts|
  d = Y::Doc.new
  Array(parts).each { |b| d.apply_update(b) }
  d.read_text("body")
}
ok = expected.nil? || keys.all? do |k|
  text_of.call(model.load_state(k)) == expected &&
    (STORE != "pg" || text_of.call(model.select(:id).find_by(key: k).sync_diff("\x00".b)) == expected)
end

n = wl.size
printf "%-13s %-6s %2d docs x %3d KB, %2d writers: %6.0f appends/s  append p50 %5.2f p99 %6.2f max %6.1fms | " \
       "join p50 %5.2f p99 %6.2fms (%5d) | WAL %5.1f KB/edit  churn %6.2f/edit  dead %5d  autovac %2d  size %5.1f MB | ok %s%s\n",
       model.name, MODE, DOCS, SIZE, WRITERS, n / wall, pct.call(wl, 0.5), pct.call(wl, 0.99), wl.max * 1000,
       pct.call(jl, 0.5), pct.call(jl, 0.99), jl.size, wal / n / 1024, churn.to_f / n, dead, autovac, size / 1e6, ok,
       errors.empty? ? "" : "  errors #{errors}"
