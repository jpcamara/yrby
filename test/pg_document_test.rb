# frozen_string_literal: true

require_relative "document_channel_test"
require "y/pg_ydoc"
require_relative "../app/models/y/pg_document"

# Y::PgDocument against a real Postgres with the pg_ydoc extension (see
# pg_ydoc/README.md to build it). Skipped unless YRBY_PG_URL points at one,
# e.g.
#
#   YRBY_PG_URL=postgres://localhost:28817/postgres bundle exec rake test
#
# The rest of the suite stays on SQLite; only Y::PgDocument connects here.
PG_DOCUMENT_URL = ENV.fetch("YRBY_PG_URL", nil)

if PG_DOCUMENT_URL
  require "active_record/connection_adapters/postgresql_adapter"
  Y::PgYdoc.register_type(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
  Y::PgDocument.establish_connection(url: PG_DOCUMENT_URL, pool: 12)
  Y::PgDocument.connection.execute(<<~SQL)
    CREATE EXTENSION IF NOT EXISTS pg_ydoc;
    DROP TABLE IF EXISTS y_document_updates, y_documents, y_document_log, y_document_log_slot;
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
  Y::PgDocument.connection.execute(Y::PgDocument::SCHEMA)
  Y::PgDocument.reset_column_information
  Minitest.after_run do
    Y::PgDocument.connection.execute("DROP TABLE y_document_updates, y_documents, y_document_log, y_document_log_slot")
  end
end

class PgDocumentTest < ActionCable::Channel::TestCase
  tests Y::DocumentChannel

  class PgPage < DocumentChannelTest::Page
    has_collaborative_document :body, store: :pg_ydoc
  end

  def setup
    skip "set YRBY_PG_URL to a Postgres with pg_ydoc" unless PG_DOCUMENT_URL
    Y::PgDocument.connection.execute("TRUNCATE y_document_updates, y_documents, y_document_log")
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

  # Log rows not yet folded into the document's snapshot.
  def log_rows(key)
    Y::PgDocument.connection.select_value(<<~SQL).to_i
      SELECT count(*) FROM y_documents d JOIN y_document_log l ON #{Y::PgDocument::UNFOLDED}
       WHERE d.key = #{Y::PgDocument.connection.quote(key)}
    SQL
  end

  # Every row in the log, folded or not.
  def stored_log_rows = Y::PgDocument.connection.select_value("SELECT count(*) FROM y_document_log").to_i

  # Apply what sync_diff returned: one update or several, in order.
  def apply_all(doc, updates) = Array(updates).each { |u| doc.apply_update(u) }

  def with_policy(**settings)
    saved = settings.keys.to_h { |k| [k, Y::PgDocument.public_send(k)] }
    settings.each { |k, v| Y::PgDocument.public_send(:"#{k}=", v) }
    yield
  ensure
    saved.each { |k, v| Y::PgDocument.public_send(:"#{k}=", v) }
  end

  def test_state_reads_as_binary_without_a_type_warning
    Y::PgDocument.append("k", typing(1).first.first)
    Y::PgDocument.find_by(key: "k").compact!

    state = Y::PgDocument.find_by(key: "k").state

    assert_equal Encoding::BINARY, state.encoding
    assert_equal Y::PgDocument.load_state("k"), state
  end

  def test_appends_load_and_compact
    updates, expected = typing(150)
    with_policy(compact_min_log_bytes: 1024, check_compaction_every: 1) do
      updates.each { |u| Y::PgDocument.append("doc", u) }
    end

    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    assert_operator log_rows("doc"), :<, 100, "the log compacted once its bytes passed the floor"
    assert_nil Y::PgDocument.load_state("missing")
  end

  # A large snapshot isn't rewritten until the log reaches a share of it.
  def test_compaction_waits_for_the_log_to_reach_a_share_of_the_snapshot
    updates, expected = typing(400, seed: 9)
    base = updates[0...300]
    rest = updates[300..]
    base.each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!
    snapshot = Y::PgDocument.connection.select_value("SELECT pg_column_size(state) FROM y_documents").to_i
    logged = 0
    with_policy(compact_min_log_bytes: 0, compact_log_ratio: 0.5, check_compaction_every: 1) do
      rest.each do |u|
        Y::PgDocument.append("doc", u)
        logged += u.bytesize
        break if log_rows("doc").zero?
      end
    end

    assert_operator logged, :>=, snapshot / 2, "no compaction before the log reached half the snapshot"
    assert_equal 0, log_rows("doc"), "and one once it did"
    rest.each { |u| Y::PgDocument.append("doc", u) }

    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
  end

  # The snapshot goes out as stored and the log as a second update; the state
  # vector comes from the stored one plus the log.
  def test_sync_serves_snapshot_and_log_apart
    updates, expected = typing(60, seed: 10)
    updates[0...40].each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!
    updates[40..].each { |u| Y::PgDocument.append("doc", u) }
    snapshot = Y::PgDocument.find_by(key: "doc").state

    parts = Y::PgDocument.sync_diff("doc", "\x00".b)

    assert_equal 2, parts.size
    assert_equal snapshot.b, parts.first.b, "a client with nothing gets the snapshot as stored"
    client = Y::Doc.new
    apply_all(client, parts)

    assert_equal expected, client.read_text("t")
    full = Y::Doc.new
    updates.each { |u| full.apply_update(u) }

    assert_equal full.encode_state_vector, Y::PgDocument.sync_state("doc")
    apply_all(full, Y::PgDocument.sync_diff("doc", full.encode_state_vector))

    assert_equal expected, full.read_text("t"), "an up-to-date client gets nothing new"
  end

  def stored_state_vector = Y::PgDocument.connection.select_value("SELECT state_vector FROM y_documents")

  # Compaction folds only what fits below a gap; the rest stays in the log
  # so the snapshot keeps a stored state vector and is served apart.
  def test_compaction_leaves_rows_past_a_gap_in_the_log
    updates, = typing(3, seed: 11)
    Y::PgDocument.append("doc", updates[0])
    Y::PgDocument.append("doc", updates[2]) # depends on the missing updates[1]
    Y::PgDocument.find_by(key: "doc").compact!

    refute_nil stored_state_vector, "the snapshot has no gap"
    assert_equal 1, log_rows("doc"), "the row past the gap waits in the log"
    assert_equal text_of(updates[0]), text_of(Y::PgDocument.find_by(key: "doc").state)

    Y::PgDocument.append("doc", updates[1])
    full = Y::Doc.new
    apply_all(full, updates)

    assert_equal full.encode_state_vector, Y::PgDocument.sync_state("doc")
    client = Y::Doc.new
    apply_all(client, Y::PgDocument.sync_diff("doc", "\x00".b))

    assert_equal full.read_text("t"), client.read_text("t")

    Y::PgDocument.find_by(key: "doc").compact!

    assert_equal 0, log_rows("doc"), "with the gap closed everything folds"
    assert_equal full.read_text("t"), text_of(Y::PgDocument.find_by(key: "doc").state)
  end

  # The rows compaction leaves in the log carry its own transaction id,
  # which Postgres counts as visible in its own snapshot once a later
  # transaction has committed. The folded snapshot must not cover them.
  def test_rows_left_past_a_gap_survive_compaction_inside_a_transaction
    updates, = typing(3, seed: 12)
    Y::PgDocument.transaction do
      Y::PgDocument.append("doc", updates[0])
      Y::PgDocument.append("doc", updates[2])
      Thread.new do
        Y::PgDocument.connection_pool.with_connection do |c|
          c.transaction { c.select_value("SELECT pg_current_xact_id()") }
        end
      end.join
      Y::PgDocument.find_by(key: "doc").compact!
    end
    Y::PgDocument.append("doc", updates[1])
    Y::PgDocument.find_by(key: "doc").compact!
    full = Y::Doc.new
    apply_all(full, updates)

    assert_equal full.read_text("t"), text_of(Y::PgDocument.load_state("doc"))
  end

  # Recorded orders that once lost content when compaction kept rows past a
  # gap out of the snapshot (pg_ydoc/tests/fixtures/out-of-order), through
  # the store, compacting every few appends.
  def test_out_of_order_fixtures_survive_compaction_that_keeps_rows_past_gaps
    fixtures = Dir[File.expand_path("../pg_ydoc/tests/fixtures/out-of-order/*.hex", __dir__)]

    assert_operator fixtures.size, :>=, 10
    fixtures.each do |path|
      updates = File.readlines(path, chomp: true).reject(&:empty?).map { |h| [h].pack("H*") }
      body = JSON.parse(File.read(path.sub(/\.hex\z/, ".json")))["body"]
      [3, 7].each do |every|
        key = "#{File.basename(path)}/#{every}"
        updates.each_with_index do |u, i|
          Y::PgDocument.append(key, u)
          Y::PgDocument.find_by(key: key).compact! if i % every == every - 1
        end
        Y::PgDocument.find_by(key: key).compact!
        client = Y::Doc.new
        apply_all(client, Y::PgDocument.sync_diff(key, "\x00".b))

        assert_equal body, client.read_text("body"), "#{key}: served"
        assert_equal body, text_of_body(Y::PgDocument.load_state(key)), "#{key}: loaded"
        assert_equal 0, log_rows(key), "#{key}: everything folds once nothing is missing"
      end
    end
  end

  def text_of_body(bytes)
    doc = Y::Doc.new
    doc.apply_update(bytes)
    doc.read_text("body")
  end

  # A snapshot that does hold content past a gap (written before compaction
  # kept them out, say) has no stored state vector and is served merged.
  def test_a_snapshot_with_a_gap_is_served_merged
    updates, = typing(3, seed: 11)
    Y::PgDocument.append("doc", updates[0])
    Y::PgDocument.connection.exec_update(
      "UPDATE y_documents SET state = ydoc_apply(ydoc_apply(NULL, $1), $2)", "gapped",
      [ActiveRecord::Relation::QueryAttribute.new("u0", updates[0], ActiveRecord::Type::Binary.new),
       ActiveRecord::Relation::QueryAttribute.new("u2", updates[2], ActiveRecord::Type::Binary.new)]
    )
    Y::PgDocument.append("doc", updates[1])

    assert_nil stored_state_vector
    served = Y::PgDocument.sync_diff("doc", "\x00".b)

    assert_kind_of String, served
    full = Y::Doc.new
    apply_all(full, updates)

    assert_equal full.read_text("t"), text_of(served)
    assert_equal full.encode_state_vector, Y::PgDocument.sync_state("doc")
  end

  def test_shuffled_updates_converge_into_a_snapshot_without_gaps
    updates, expected = typing(200, seed: 2)
    order = updates.shuffle(random: Random.new(3))
    order.each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!

    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    refute Y::PgDocument.connection.select_value(
      "SELECT ydoc_has_pending(state) FROM y_documents WHERE key = 'doc'"
    )
  end

  def test_sync_serves_pending_content_and_the_client_heals
    updates, = typing(3, seed: 4)
    Y::PgDocument.append("doc", updates[0])
    Y::PgDocument.append("doc", updates[2]) # depends on the missing updates[1]

    sv = Y::PgDocument.sync_state("doc")
    reference = Y::Doc.new
    reference.apply_update(updates[0])

    assert_equal reference.encode_state_vector, sv, "the state vector stops at the gap"

    client = Y::Doc.new
    apply_all(client, Y::PgDocument.sync_diff("doc", client.encode_state_vector))

    assert_predicate client, :pending?, "the client holds the gap"
    client.apply_update(updates[1])
    full = Y::Doc.new
    updates.each { |u| full.apply_update(u) }

    assert_equal full.read_text("t"), client.read_text("t")
  end

  def test_sync_for_a_document_that_does_not_exist_yet
    assert_equal "\x00".b, Y::PgDocument.sync_state("nothing")
    update = Y::PgDocument.sync_diff("nothing", "\x00".b)

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
    rotations = 0
    rotator = Thread.new do
      while writing
        rotations += 1 if Y::PgDocument.rotate_log!
        sleep 0.002
      end
    end
    reader = Thread.new do
      last = 0
      while writing
        sv = doc.sync_state
        sum = clock_sum(sv)
        regressions += 1 if sum < last
        last = sum
      end
    end
    writers.each(&:join)
    writing = false
    [compactor, reader, rotator].each(&:join)
    doc.compact!
    2.times { Y::PgDocument.rotate_log! }

    assert_operator rotations, :>, 0
    assert_equal 0, stored_log_rows, "two rotations after the last compaction leave nothing"
    assert_equal 0, regressions
    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
    assert_equal 0, log_rows("doc")
  end

  # Rotation keeps what isn't folded yet, drops what is (and rows of deleted
  # documents), and only touches the older partition.
  def test_rotation_carries_unfolded_rows_and_truncates_the_rest
    updates, expected = typing(30, seed: 12)
    updates[0...20].each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!
    updates[20..].each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.append("gone", updates[0])
    Y::PgDocument.where(key: "gone").delete_all

    assert Y::PgDocument.rotate_log!, "the first rotation empties the unused partition"
    assert_equal 31, stored_log_rows
    assert Y::PgDocument.rotate_log!

    assert_equal 10, stored_log_rows, "only the unfolded rows were carried"
    assert_equal 10, log_rows("doc")
    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
  end

  def test_rotation_waits_for_no_transaction
    Y::PgDocument.transaction do
      refute Y::PgDocument.rotate_log!
    end
  end

  def test_another_cluster_must_be_adopted_before_compaction_or_rotation
    updates, expected = typing(20, seed: 13)
    updates[0...10].each { |u| Y::PgDocument.append("doc", u) }
    Y::PgDocument.find_by(key: "doc").compact!
    updates[10..].each { |u| Y::PgDocument.append("doc", u) }
    c = Y::PgDocument.connection
    c.execute("UPDATE y_document_log_slot SET system_identifier = 0")

    assert_raises(Y::PgDocument::OtherCluster) { Y::PgDocument.find_by(key: "doc").compact! }
    assert_raises(Y::PgDocument::OtherCluster) { Y::PgDocument.rotate_log! }
    Y::PgDocument.adopt_log!
    Y::PgDocument.find_by(key: "doc").compact!
    2.times { Y::PgDocument.rotate_log! }

    assert_equal 0, stored_log_rows
    assert_equal expected, text_of(Y::PgDocument.load_state("doc"))
  end

  def test_the_shipped_channel_serves_a_pg_ydoc_document_without_loading_it
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

  def test_pg_ydoc_store_rejects_encryption_and_unknown_stores
    assert_raises(ArgumentError) do
      Class.new(PgPage) { has_collaborative_document :x, store: :pg_ydoc, encrypted: true }
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
