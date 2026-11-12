# frozen_string_literal: true

require_relative "document_channel_test"
require "y/pg_yrby"
require_relative "../app/models/y/pg_document"

# Y::PgDocument against a real Postgres with the pg_yrby extension (see
# pg_yrby/README.md to build it). Skipped unless YRBY_PG_URL points at one,
# e.g.
#
#   YRBY_PG_URL=postgres://localhost:28817/postgres bundle exec rake test
#
# The rest of the suite stays on SQLite; only Y::PgDocument connects here.
PG_DOCUMENT_URL = ENV.fetch("YRBY_PG_URL", nil)

if PG_DOCUMENT_URL
  require "active_record/connection_adapters/postgresql_adapter"
  Y::PgYrby.register_type(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
  Y::PgDocument.establish_connection(url: PG_DOCUMENT_URL, pool: 12)
  Y::PgDocument.connection.execute(<<~SQL)
    CREATE EXTENSION IF NOT EXISTS pg_yrby;
    DROP TABLE IF EXISTS y_document_updates, y_documents;
    CREATE TABLE y_documents (
      id bigserial PRIMARY KEY,
      key varchar NOT NULL,
      record_type varchar, record_id bigint, name varchar,
      state ydoc,
      created_at timestamp(6) NOT NULL, updated_at timestamp(6) NOT NULL
    );
    CREATE UNIQUE INDEX ON y_documents (key);
    CREATE UNIQUE INDEX ON y_documents (record_type, record_id, name) WHERE record_type IS NOT NULL;
    CREATE TABLE y_document_updates (
      id bigserial PRIMARY KEY,
      document_id bigint NOT NULL REFERENCES y_documents,
      payload bytea NOT NULL,
      pending boolean NOT NULL DEFAULT false,
      created_at timestamp(6) NOT NULL
    );
    CREATE INDEX ON y_document_updates (document_id, pending);
  SQL
  Y::PgDocument.reset_column_information
  Minitest.after_run { Y::PgDocument.connection.execute("DROP TABLE y_document_updates, y_documents") }
end

class PgDocumentTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class PgPage < DocumentChannelTest::Page
    has_collaborative_document :body, store: :pg_yrby
  end

  def setup
    skip "set YRBY_PG_URL to a Postgres with pg_yrby" unless PG_DOCUMENT_URL
    Y::PgDocument.connection.execute("TRUNCATE y_document_updates, y_documents")
    @original_authorizer = Y::DocumentChannel.document_authorizer
    stub_connection
  end

  def teardown
    Y::DocumentChannel.document_authorizer = @original_authorizer if PG_DOCUMENT_URL
  end

  # A typing session from one client: the updates and the final text.
  def typing(edits, seed: 1)
    rand = Random.new(seed)
    doc = Y::Doc.new
    text = doc.get_text("t")
    updates = Array.new(edits) do
      doc.edit do
        if rand.rand < 0.2 && text.length > 3
          text.delete(rand.rand(text.length - 2), 1)
        else
          text.insert(rand.rand(text.length + 1), %w[a bc d🙂 é].sample(random: rand))
        end
      end
    end
    [updates, text.to_s]
  end

  def text_of(bytes)
    doc = Y::Doc.new
    doc.apply_update(bytes) if bytes
    doc.read_text("t")
  end

  def log_rows(key) = Y::PgDocument.find_by(key: key).updates.count

  def test_state_reads_as_binary_without_a_type_warning
    Y::PgDocument.append("k", typing(1).first.first)
    Y::PgDocument.find_by(key: "k").compact!

    state = Y::PgDocument.find_by(key: "k").state

    assert_equal Encoding::BINARY, state.encoding
    assert_equal Y::PgDocument.load_state("k"), state
  end

  def test_appends_load_and_compact
    updates, expected = typing(150)
    updates.each { |u| Y::PgDocument.append("doc", u) }

    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    assert_operator Y::PgDocument.connection.select_value("SELECT count(*) FROM y_document_updates").to_i,
                    :<, Y::PgDocument.compact_every, "the log compacted as it grew"
    assert_nil Y::PgDocument.load_state("missing")
  end

  def test_shuffled_updates_wait_in_the_snapshot_and_converge
    updates, expected = typing(200, seed: 2)
    order = updates.shuffle(random: Random.new(3))
    order.each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!

    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    assert_equal [false], Y::PgDocument.sync_state("doc").values_at(1)
  end

  def test_sync_serves_pending_content_and_the_client_heals
    updates, = typing(3, seed: 4)
    Y::PgDocument.append("doc", updates[0])
    Y::PgDocument.append("doc", updates[2]) # depends on the missing updates[1]

    sv, pending = Y::PgDocument.sync_state("doc")

    assert pending
    reference = Y::Doc.new
    reference.apply_update(updates[0])

    assert_equal reference.encode_state_vector, sv, "the state vector stops at the gap"

    client = Y::Doc.new
    update, = Y::PgDocument.sync_diff("doc", client.encode_state_vector)
    client.apply_update(update)

    assert_predicate client, :pending?, "the client holds the gap"
    client.apply_update(updates[1])
    full = Y::Doc.new
    updates.each { |u| full.apply_update(u) }

    assert_equal full.read_text("t"), client.read_text("t")
  end

  def test_sync_for_a_document_that_does_not_exist_yet
    assert_equal ["\x00".b, false], Y::PgDocument.sync_state("nothing")
    update, pending = Y::PgDocument.sync_diff("nothing", "\x00".b)

    refute pending
    assert_nil text_of(update)
  end

  # Writers, a compactor and a reader on one document at once, each on its
  # own connection. The reader's state vector must never go backwards, which
  # a compaction that isn't atomic would show.
  def test_concurrent_writers_compactions_and_reads_converge
    updates, expected = typing(400, seed: 5)
    order = (updates + updates.sample(40, random: Random.new(6))).shuffle(random: Random.new(7))
    Y::PgDocument.append("doc", order.shift)
    doc = Y::PgDocument.find_by(key: "doc")
    writing = true
    regressions = 0

    writers = 6.times.map do |w|
      Thread.new do
        order.each_with_index { |u, i| Y::PgDocument.append("doc", u) if i % 6 == w }
      end
    end
    compactor = Thread.new { doc.compact! while writing }
    reader = Thread.new do
      last = 0
      while writing
        sv, = doc.sync_state
        sum = clock_sum(sv)
        regressions += 1 if sum < last
        last = sum
      end
    end
    writers.each(&:join)
    writing = false
    [compactor, reader].each(&:join)
    doc.compact!

    assert_equal 0, regressions
    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    assert_equal 0, log_rows("doc")
  end

  def test_the_shipped_channel_serves_a_pg_yrby_document_without_loading_it
    page = PgPage.create!(title: "pg")
    updates, expected = typing(80, seed: 8)
    attribute = page.collaborative_document(:body)
    updates.each { |u| attribute.append(u) }

    loads = 0
    Y::PgDocument.alias_method(:counted_load_state, :load_state)
    Y::PgDocument.define_method(:load_state) do
      loads += 1
      counted_load_state
    end
    begin
      subscribe grant: attribute.grant, name: "body"

      assert_predicate subscription, :confirmed?
      client = Y::Doc.new
      perform :receive, "update" => Base64.strict_encode64(client.sync_step1)
      transmissions.each { |t| client.handle_sync_message(Base64.strict_decode64(t["update"])) if t["update"] }
    ensure
      Y::PgDocument.alias_method(:load_state, :counted_load_state)
      Y::PgDocument.remove_method(:counted_load_state)
    end

    assert_equal expected, client.read_text("t")
    assert_equal 0, loads, "the channel answered sync from SQL"
    assert_kind_of Y::PgDocument, attribute.document_row
  end

  def test_pg_yrby_store_rejects_encryption_and_unknown_stores
    assert_raises(ArgumentError) do
      Class.new(PgPage) { has_collaborative_document :x, store: :pg_yrby, encrypted: true }
    end
    assert_raises(ArgumentError) { Class.new(PgPage) { has_collaborative_document :x, store: :redis } }
  end

  private

  # The sum of a state vector's clocks: v1 is a varuint count, then
  # (client, clock) varuint pairs.
  def clock_sum(state_vector)
    bytes = state_vector.bytes
    read = lambda do
      n = 0
      shift = 0
      loop do
        b = bytes.shift
        n |= (b & 0x7f) << shift
        break if b < 0x80

        shift += 7
      end
      n
    end
    Array.new(read.call) do
      read.call # client id
      read.call # clock
    end.sum
  end
end
