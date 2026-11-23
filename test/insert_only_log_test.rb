# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"

# Y::Document's insert-only log on Postgres (yrby:insert_only_log). Skipped
# unless the suite runs on Postgres (YRBY_PG_URL, see support/active_record).
class InsertOnlyLogTest < Minitest::Test
  def setup
    skip "set YRBY_PG_URL to run on Postgres" unless YRBY_PG_URL
    connection.execute("TRUNCATE y_document_updates, y_documents CASCADE")
    Y::Document.check_compaction_every = 1
  end

  def teardown
    Y::Document.check_compaction_every = 16
    Y::Document.compact_every = 256
    Y::Document.rotate_log_every = 4096
  end

  def connection = Y::Document.connection

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

  def stored_rows = connection.select_value("SELECT count(*) FROM y_document_updates").to_i
  def current_slot = connection.select_value("SELECT slot FROM y_document_updates_slot").to_i
  def partition_rows(slot) = connection.select_value("SELECT count(*) FROM y_document_updates_#{slot}").to_i

  # The clocks in an encoded state vector (varuint count, then client/clock pairs).
  def decode_clocks(bytes)
    values = []
    value = shift = 0
    bytes.each_byte do |b|
      value |= (b & 0x7f) << shift
      shift += 7
      next if b.anybits?(0x80)

      values << value
      value = shift = 0
    end
    values.drop(1).each_slice(2).map(&:last)
  end

  def test_the_suite_runs_on_the_insert_only_log
    assert_predicate Y::Document, :insert_only_log?
  end

  def test_compaction_folds_without_deleting
    updates, expected = typing(20, seed: 2)
    Y::Document.compact_every = nil
    updates.each { |u| Y::Document.append("doc", u) }
    document = Y::Document.find_by(key: "doc")
    document.compact!

    assert_equal 20, stored_rows, "nothing deleted"
    assert_equal 0, document.tail.count, "every row folded"
    assert_equal expected, text_of(Y::Document.load_state("doc"))
    refute_nil connection.select_value("SELECT folded FROM y_documents")
  end

  # The race that rules out a high-water id: a row gets its id before its
  # transaction commits, so a compaction can see later ids first. The row
  # isn't in the snapshot compaction records, so it stays in the tail.
  # Compaction also doesn't wait for the open append (FOR NO KEY UPDATE).
  def test_a_row_committing_after_a_compaction_stays_in_the_tail
    Y::Document.compact_every = nil
    fast = Y::Doc.new
    late = Y::Doc.new
    edits = Array.new(5) { |i| fast.edit { fast.get_text("t").insert(i, "a") } }
    late_edit = late.edit { late.get_text("u").insert(0, "late") }
    Y::Document.append("doc", edits[0])
    document = Y::Document.find_by(key: "doc")
    inserted = Queue.new
    commit = Queue.new
    slow = Thread.new do
      Y::Document.transaction do
        document.updates.create!(payload: late_edit)
        inserted << true
        commit.pop
      end
    end
    inserted.pop
    edits[1..].each { |u| document.updates.create!(payload: u) }
    compacted = Thread.new { document.compact! }
    finished = compacted.join(5)
    commit << true
    slow.join
    compacted.join

    assert finished, "compaction waited for the open append"

    assert_equal [late_edit], document.tail.pluck(:payload), "only the late row is left"
    document.compact!

    assert_equal 0, document.tail.count
    loaded = Y::Doc.new
    loaded.apply_update(Y::Document.load_state("doc"))

    assert_equal %w[aaaaa late], [loaded.read_text("t"), loaded.read_text("u")]
  end

  # A row appended after compaction inside the same transaction carries the
  # compaction's own transaction id, which Postgres reads as visible in its
  # own snapshot once a later transaction has committed. The recorded
  # snapshot must still leave it unfolded.
  def test_a_row_appended_after_compaction_in_the_same_transaction_stays_in_the_tail
    updates, expected = typing(3, seed: 14)
    Y::Document.compact_every = nil
    Y::Document.append("doc", updates[0])
    document = Y::Document.find_by(key: "doc")
    other = typing(1).first.first
    document.define_singleton_method(:compaction_rows) do
      Thread.new { Y::Document.append("other", other) }.join # a later transaction commits
      super()
    end
    Y::Document.transaction do
      document.updates.create!(payload: updates[1])
      document.compact!
      document.updates.create!(payload: updates[2])
    end

    assert_operator Y::Document.find_by(key: "doc").tail.count, :>=, 1, "the late row is in the tail"
    assert_equal expected, text_of(Y::Document.load_state("doc"))
    Y::Document.find_by(key: "doc").compact!
    2.times { Y::Document.rotate_log! }

    assert_equal expected, text_of(Y::Document.load_state("doc"))
  end

  # A writer still inserting into the older partition when rotation starts:
  # rotation waits for it, so the copy sees its row.
  def test_rotation_waits_for_writers_in_the_older_partition
    Y::Document.compact_every = nil
    Y::Document.rotate_lock_timeout = "5s"
    updates, expected = typing(2, seed: 10)
    Y::Document.append("doc", updates[0])
    inserted = Queue.new
    commit = Queue.new
    slow = Thread.new do
      Y::Document.transaction do
        Y::Document.find_by(key: "doc").updates.create!(payload: updates[1])
        inserted << true
        commit.pop
      end
    end
    inserted.pop

    # Now the slow row's partition is the older one.
    assert Y::Document.rotate_log!, "the older partition was empty"
    rotation = Thread.new { Y::Document.rotate_log! }
    sleep 0.2
    commit << true
    slow.join

    assert rotation.value
    assert_equal 2, stored_rows
    assert_equal expected, text_of(Y::Document.load_state("doc"))
  ensure
    Y::Document.rotate_lock_timeout = "50ms"
  end

  # Rotation keeps what isn't folded yet and drops what is.
  def test_rotation_carries_unfolded_rows_and_truncates_the_rest
    updates, expected = typing(30, seed: 4)
    Y::Document.compact_every = nil
    updates[0...20].each { |u| Y::Document.append("doc", u) }
    Y::Document.find_by(key: "doc").compact!
    updates[20..].each { |u| Y::Document.append("doc", u) }
    Y::Document.append("gone", updates[0])
    Y::Document.find_by(key: "gone").destroy

    assert Y::Document.rotate_log!, "the first rotation empties the unused partition"
    assert_equal 30, stored_rows
    assert Y::Document.rotate_log!

    assert_equal 10, stored_rows, "only the unfolded rows were carried"
    assert_equal 10, Y::Document.find_by(key: "doc").tail.count
    assert_equal expected, text_of(Y::Document.load_state("doc"))
  end

  def test_new_rows_go_to_the_current_partition
    Y::Document.compact_every = nil
    slot = current_slot
    Y::Document.append("doc", typing(1).first.first)

    assert_equal [1, 0], [partition_rows(slot), partition_rows(1 - slot)]
    Y::Document.rotate_log!
    Y::Document.append("doc", typing(2).first.last)

    assert_equal [1, 1], [partition_rows(slot), partition_rows(1 - slot)], "the unfolded row was carried"
  end

  def test_rotation_waits_for_no_transaction
    Y::Document.transaction do
      refute Y::Document.rotate_log!
    end
  end

  def test_rotation_gives_up_when_the_older_partition_is_busy
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      Y::Document.connection_pool.with_connection do |c|
        c.transaction do
          c.execute("LOCK TABLE y_document_updates_#{1 - current_slot} IN ACCESS SHARE MODE")
          locked << true
          release.pop
        end
      end
    end
    locked.pop

    refute Y::Document.rotate_log!, "gave up after rotate_lock_timeout"
    release << true
    holder.join

    assert Y::Document.rotate_log!
  end

  def test_append_rotates_on_one_append_in_rotate_log_every
    Y::Document.compact_every = nil
    Y::Document.rotate_log_every = 1
    slot = current_slot
    updates, expected = typing(3, seed: 5)
    updates.each { |u| Y::Document.append("doc", u) }

    refute_equal slot, current_slot, "three rotations"
    assert_equal [3, 0], [partition_rows(slot), partition_rows(1 - slot)], "the last rotation carried every row"
    assert_equal expected, text_of(Y::Document.load_state("doc"))
  end

  # A gap is folded into state like anything else; rotation drops the
  # folded row, and the gap heals when the missing update arrives.
  def test_a_gap_folds_into_state_survives_rotation_and_heals
    Y::Document.append("doc", YjsFixtures::Gap::DEPENDENT)
    document = Y::Document.find_by(key: "doc")
    document.compact!

    2.times { assert Y::Document.rotate_log! }

    assert_equal 0, stored_rows
    Y::Document.append("doc", YjsFixtures::Gap::FIRST)
    document.compact!
    doc = Y::Doc.new
    doc.apply_update(Y::Document.load_state("doc"))

    assert_equal "ab", doc.read_text("notepad")
  end

  def test_another_cluster_must_be_adopted_before_compaction_or_rotation
    updates, expected = typing(20, seed: 6)
    Y::Document.compact_every = nil
    updates[0...10].each { |u| Y::Document.append("doc", u) }
    Y::Document.find_by(key: "doc").compact!
    updates[10..].each { |u| Y::Document.append("doc", u) }
    connection.execute("UPDATE y_document_updates_slot SET system_identifier = 0")

    assert_raises(Y::Document::OtherCluster) { Y::Document.find_by(key: "doc").compact! }
    assert_raises(Y::Document::OtherCluster) { Y::Document.rotate_log! }
    Y::Document.adopt_log!
    Y::Document.find_by(key: "doc").compact!
    2.times { Y::Document.rotate_log! }

    assert_equal 0, stored_rows
    assert_equal expected, text_of(Y::Document.load_state("doc"))
  end

  def test_concurrent_writers_compactions_rotations_and_reads_converge
    updates, expected = typing(400, seed: 7)
    order = (updates + updates.sample(40, random: Random.new(8))).shuffle(random: Random.new(9))
    Y::Document.compact_every = nil
    Y::Document.append("doc", order.shift)
    document = Y::Document.find_by(key: "doc")
    writing = true
    regressions = 0
    rotations = 0

    writers = 6.times.map do |w|
      Thread.new do
        order.each_with_index { |u, i| Y::Document.append("doc", u) if i % 6 == w }
      end
    end
    compactor = Thread.new { document.compact! while writing }
    rotator = Thread.new do
      while writing
        rotations += 1 if Y::Document.rotate_log!
        sleep 0.002
      end
    end
    reader = Thread.new do
      last = 0
      while writing
        sum = (sv = Y::Document.sync_state("doc")) ? decode_clocks(sv).sum : last
        regressions += 1 if sum < last
        last = sum
      end
    end
    writers.each(&:join)
    writing = false
    [compactor, reader, rotator].each(&:join)
    document.compact!
    2.times { Y::Document.rotate_log! }

    assert_operator rotations, :>, 0
    assert_equal 0, stored_rows, "two rotations after the last compaction leave nothing"
    assert_equal 0, regressions, "the state vector never went backwards"
    assert_equal expected, text_of(Y::Document.load_state("doc"))
  end
end
