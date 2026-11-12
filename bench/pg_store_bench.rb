# Y::Document vs Y::PgDocument (same model API, Yjs work in the pg_yrby
# extension), called as the channel calls them. STORE=yrby|pg, needs a
# Postgres with pg_yrby on :28817 and WORKLOAD_DIR with w2/w50/w500.txt.
require "active_record"
require "pg"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "y"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/pg_document"
require "y/pg_yrby"
require "active_record/connection_adapters/postgresql_adapter"
Y::PgYrby.register_type(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)

STORE = ENV.fetch("STORE")
model = STORE == "pg" ? Y::PgDocument : Y::Document
ActiveRecord::Base.establish_connection(adapter: "postgresql", host: "localhost", port: 28817, database: "postgres")
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.verbose = false
conn = ActiveRecord::Base.connection
conn.execute("create extension if not exists pg_yrby")
conn.execute("drop table if exists y_document_updates, y_documents")
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
conn.execute("alter table y_documents alter column state type ydoc using ydoc(state)") if STORE == "pg"

now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
median = ->(n, &blk) { s = Array.new(n) { t = now.(); blk.(); now.() - t }.sort; s[n / 2] * 1000 }
varuint = ->(n) { out = +"".b; loop { b = n & 0x7f; n >>= 7; out << (n.zero? ? b : b | 0x80).chr; break if n.zero? }; out }
text_of = ->(bytes) { d = Y::Doc.new; d.apply_update(bytes); d.read_text("body") }

[2, 50, 500].each do |kb|
  seed, half_sv, expected, *updates = File.readlines(File.join(ENV.fetch("WORKLOAD_DIR"), "w#{kb}.txt"), chomp: true).map { |h| [h].pack("H*") }
  expected.force_encoding("UTF-8")
  step1 = "\x00\x00".b + varuint.(half_sv.bytesize) + half_sv
  key = "bench/#{kb}"

  model.append(key, seed)
  t = now.()
  updates.each { |u| model.append(key, u) }
  write = (now.() - t) * 1000 / updates.size
  doc = model.select(:id).find_by(key: key)

  # Join as Y::DocumentChannel does it: load into a Y::Doc, send SyncStep1;
  # load again for the client's SyncStep1 and answer with the diff.
  ruby_join = median.(30) do
    d = Y::Doc.new; d.apply_update(model.load_state(key)); d.sync_step1
    d2 = Y::Doc.new; d2.apply_update(model.load_state(key)); d2.handle_sync_message(step1)
  end
  sql_join = STORE == "pg" ? median.(30) { doc.sync_state; doc.sync_diff(half_sv) } : nil
  ok = text_of.(model.load_state(key)) == expected
  ok &&= text_of.(doc.sync_diff("\x00".b).first) == expected if STORE == "pg"

  # Out of order: every update shuffled, compacting as it goes.
  okey = "shuffled/#{kb}"
  model.append(okey, seed)
  updates.shuffle(random: Random.new(kb)).each { |u| model.append(okey, u) }
  shuffled_ok = text_of.(model.load_state(okey)) == expected

  printf "%-7s %-18s write %6.2fms  join (Ruby sync) %6.2fms  join (SQL sync) %8s  ok %s  shuffled ok %s\n",
         "#{kb} KB", model.name, write, ruby_join, sql_join ? format("%.2fms", sql_join) : "-", ok, shuffled_ok
end
conn.execute("drop table y_document_updates, y_documents")
