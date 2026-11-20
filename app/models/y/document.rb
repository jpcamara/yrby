# frozen_string_literal: true

# One row per collaborative document, addressed two ways:
#
#   key             what a channel addresses: one opaque, unique string.
#                   Apps can supply their own ("room-42"), so nothing
#                   parses meaning out of a key.
#   record + name   which model attribute the document backs, where name
#                   is the attribute name ("body"). Optional, one
#                   document per attribute per record, the same scheme as
#                   ActionText::RichText.
#
# When a binding exists and no key was supplied, the key derives as
# post/1/body. Either side can arrive first (a channel can write under a
# key before any binding exists), so `.for` adopts a key-only row whose
# key matches the derived one, converging both on one row.
#
# `state` holds the merged snapshot; the update rows are the uncompacted
# tail, so a load reads the snapshot plus whatever the tail currently
# holds. The models store CRDT state only: derived data (rendered HTML,
# search text) is the application's job, typically done in the channel's
# on_change.
class Y::Document < ActiveRecord::Base
  self.table_name = "y_documents"

  belongs_to :record, polymorphic: true, optional: true
  has_many :updates, class_name: "Y::DocumentUpdate", dependent: :delete_all

  validates :key, presence: true
  # A bound row carries record + name. Checked on the columns, not the
  # association: reading `record` constantizes record_type, which must not
  # be a validity requirement.
  validates :name, presence: true, if: :record_type
  validates :record_type, presence: true, if: -> { name || record_id }
  validates :record_id, presence: true, if: :record_type
  before_validation :assign_default_key, on: :create

  # When an append compacts the tail into state. Compaction rewrites the
  # whole snapshot, so it waits until the tail's bytes reach
  # compact_log_ratio of the snapshot's, or compact_min_log_bytes for a
  # small one: a large document is rewritten rarely, a small one often.
  # compact_every also compacts once the tail holds that many rows, so loads
  # (which apply every tail row) stay quick for a large document; nil turns
  # it off. The check reads the tail's size, so it runs on about one append
  # in check_compaction_every.
  class_attribute :compact_log_ratio, instance_writer: false, default: 0.1
  class_attribute :compact_min_log_bytes, instance_writer: false, default: 4096
  class_attribute :compact_every, instance_writer: false, default: 256
  class_attribute :check_compaction_every, instance_writer: false, default: 16

  # An update with nothing in it, the SyncStep2 for a client that is
  # missing nothing.
  EMPTY_UPDATE = "\x00\x00".b

  class << self
    def locate(key) = find_by(key: key)

    def locate!(key)
      find_by(key: key) || create_or_find_by!(key: key)
    end

    # The document bound to a record's attribute, created on first use.
    # Find first (after the first call, every call is a read), then adopt:
    # if a channel already appended under the key this binding derives, a
    # key-only row exists whose key is taken; claiming it converges the two
    # identities where a plain insert would collide on the key index.
    #
    # The insert can still lose a race it can't see: a channel creates the
    # key-only row after adopt looked and before the insert lands, so
    # create_or_find_by! collides on the key index, and its internal
    # retry, which looks up by record + name, misses the key-only row and
    # raises RecordNotFound. One more pass adopts the row that won.
    def for(record, name)
      attempts = 0
      begin
        find_by(record: record, name: name.to_s) ||
          adopt(record, name) ||
          create_or_find_by!(record: record, name: name.to_s)
      rescue ActiveRecord::RecordNotFound
        raise if (attempts += 1) > 1

        retry
      end
    end

    # The store contract for a sync channel, keyed by the transport key.
    # Both skip the state blob (select(:id)): append never reads it, and
    # load_state re-reads it fresh after the tail (see below), so neither
    # should drag a potentially large snapshot over the wire per call.
    def load_state(key) = select(:id).find_by(key: key)&.load_state

    # The same as separate updates, snapshot first, for a caller that applies
    # them to a Y::Doc of its own anyway (see load_parts).
    def load_parts(key) = select(:id).find_by(key: key)&.load_parts

    def append(key, update)
      (select(:id).find_by(key: key) || create_or_find_by!(key: key)).append(update)
    end

    # The sync handshake answered from the stored rows (see #sync_state and
    # #sync_diff), or nil for the channel to load the document instead.
    def sync_state(key) = select(:id).find_by(key: key)&.sync_state
    def sync_diff(key, state_vector) = select(:id).find_by(key: key)&.sync_diff(state_vector)

    # Whether y_documents has the state_vector column (added by
    # `bin/rails generate yrby:state_vector`). Without it the handshake
    # reads the snapshot's state vector from its bytes instead.
    def stores_state_vector? = column_names.include?("state_vector")

    # The key for one attribute of one record, such as "post/1/body". It comes
    # from the class name, id, and attribute, so computing it reads and creates
    # no rows. That means a key exists before the first write, and for custom
    # stores that never have a row. polymorphic_name is what Rails writes to
    # record_type, so STI subclasses and namespaced models get the same key.
    def key_for(record, name)
      "#{record.class.polymorphic_name.underscore}/#{record.id}/#{name}"
    end

    private

    def adopt(record, name)
      document = find_by(key: key_for(record, name), record_type: nil)
      document&.update!(record: record, name: name.to_s)
      document
    rescue ActiveRecord::RecordNotUnique
      find_by(record: record, name: name.to_s) # a racer adopted or created it first
    end
  end

  # Record one delta, and on about one append in check_compaction_every
  # compact if the tail is due. The trigger is at-or-over (concurrent appends
  # can jump past a threshold) and counts only clean rows: pending rows never
  # satisfy it, so a quarantined gap doesn't retrigger compaction.
  def append(bytes)
    row = updates.create!(payload: bytes)
    compact! if compaction_check?(row) && compaction_due?
  end

  # The merged document: state plus the whole tail. The tail is read first
  # and the snapshot re-read after it, both straight from the database: a
  # compaction committing between the two reads then hands us rows already
  # folded into the fresh snapshot, an idempotent double-apply, where
  # the reverse order could pair a pre-compaction snapshot with an empty
  # tail and omit committed changes. Quarantined rows are applied too,
  # and the output is lossless (encode_state_as_update): an unhealed gap
  # rides along as a pending struct, so a peer loaded mid-gap holds the
  # parked edit and heals it the moment the missing dependency arrives,
  # while a gap healed by a newer tail row is served merged immediately.
  def load_state
    snapshot, *tail = load_parts
    return snapshot if tail.empty?

    doc = Y::Doc.new
    doc.apply_update(snapshot) if snapshot
    tail.each { |payload| doc.apply_update(payload) }
    doc.encode_state_as_update
  end

  # The snapshot (nil before the first compaction) and then the tail rows,
  # read in the order load_state explains. Applying them in order to a
  # Y::Doc gives the merged document without load_state's merge and
  # re-encode, which the channel would only decode again.
  def load_parts
    tail = updates.reset.pluck(:payload) # reset: never a cached tail
    [self.class.where(id: id).pick(:state), *tail]
  end

  # The state vector for the server's SyncStep1: the snapshot's, extended by
  # what the tail adds after it. The snapshot's comes from the state_vector
  # column, so the snapshot isn't read at all. The tail is read first, as in
  # load_parts. nil while a row is marked pending: a gap that outlived a
  # compaction, which the channel then loads the document to see (on_gap).
  def sync_state
    tail = clean_tail or return
    Y.extend_state_vector(snapshot_state_vector || "".b, tail)
  end

  # What a client at state_vector is missing, as updates to send in order:
  # the snapshot's part, then the tail as stored. A client with nothing gets
  # the snapshot's bytes as they are; any other gets Y.diff_update of them,
  # which slices the encoded update without building a document and keeps
  # the whole delete set (a delete doesn't move a state vector, so a client
  # can lack one whatever its state vector says). nil as in sync_state.
  def sync_diff(state_vector)
    tail = clean_tail or return
    snapshot = self.class.where(id: id).pick(:state)
    snapshot = Y.diff_update(snapshot, state_vector) if snapshot && state_vector.bytesize > 1
    parts = [snapshot, *tail].compact
    parts.empty? ? [EMPTY_UPDATE] : parts
  end

  # Compact the tail into state. The row lock serializes racing
  # compactions; a delta landing mid-compaction isn't in `rows`, so it
  # survives the delete and compacts next time.
  #
  # One fold of state plus every row. compacted_state_update keeps every
  # struct that integrated, so rows independent of a gap land in state no
  # matter how they interleave with it. Each row is judged against the
  # folded doc's state vector: a row holding nothing past it is fully
  # captured and deleted; a row that reaches past it carries a gap (or
  # builds on one) and stays, marked pending, until a later compaction can
  # fold it. Every row is judged, not only when the doc reports pending:
  # yrs leaves an update that skips ahead of its client's clock
  # unintegrated without reporting it pending when the structs it attaches
  # to are present. The check reads the state vector, not the document, so
  # it costs little. An acked update never leaves the table before its
  # content is durably in state.
  def compact!
    with_lock do
      rows = updates.pluck(:id, :payload, :pending)
      next if rows.empty?

      doc = Y::Doc.new
      doc.apply_update(state) if state
      rows.each { |_, payload, _| doc.apply_update(payload) }
      captured, kept = split_rows(doc, rows)
      new_state = doc.compacted_state_update
      # A gap-only batch integrates nothing, so state is left as it was.
      write_state(doc, new_state) unless kept.any? && new_state == (state || Y::Doc.new.compacted_state_update)
      updates.where(id: captured.map(&:first)).delete_all
      updates.where(id: kept.reject(&:last).map(&:first)).update_all(pending: true)
    end
  end

  private

  # The rows the folded doc fully holds, and the rows reaching past its
  # state vector.
  def split_rows(doc, rows)
    rows.partition { |_, payload, _| doc.update_fits?(payload) }
  end

  # The new snapshot, and its state vector where the column exists.
  def write_state(doc, new_state)
    attributes = { state: new_state }
    attributes[:state_vector] = doc.encode_state_vector if self.class.stores_state_vector?
    update!(attributes)
  end

  # The tail's payloads, or nil if any row is marked pending.
  def clean_tail
    rows = updates.reset.pluck(:payload, :pending)
    rows.map(&:first) unless rows.any?(&:last)
  end

  # The snapshot's state vector: the stored one, or read from the snapshot's
  # bytes for a row compacted before the column existed. nil before the
  # first compaction.
  def snapshot_state_vector
    if self.class.stores_state_vector?
      stored, snapshot = self.class.where(id: id).pick(:state_vector, Arel.sql("state IS NOT NULL"))
      return stored if stored || !snapshot
    end
    snapshot = self.class.where(id: id).pick(:state)
    snapshot && Y.state_vector_of(snapshot)
  end

  # About one append in check_compaction_every, by row id (at random for
  # non-integer ids), so most appends skip the size query.
  def compaction_check?(row)
    every = [check_compaction_every.to_i, 1].max
    ((row.id.is_a?(Integer) ? row.id : rand(every)) % every).zero?
  end

  # Whether the clean tail has reached the compaction policy.
  def compaction_due?
    rows, bytes = updates.where(pending: false)
                         .pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(LENGTH(payload)), 0)"))
    return true if compact_every && rows.to_i >= compact_every

    snapshot = self.class.where(id: id).pick(Arel.sql("COALESCE(LENGTH(state), 0)"))
    bytes.to_i >= [compact_min_log_bytes, compact_log_ratio * snapshot.to_i].max
  end

  # Derives post/1/body from the polymorphic record_type. Rails stores
  # the polymorphic_name there, which is base_class-derived, so STI
  # subclasses share a key. Namespaces keep their slash
  # (admin/post/1/body); flattening would collide Admin::Post with
  # AdminPost. record_id is nil for an unsaved record at validation time
  # (autosave runs after), so it guards too. Key-only documents supply
  # their own key.
  def assign_default_key
    self.key ||= record_type && record_id && "#{record_type.underscore}/#{record_id}/#{name}"
  end
end
