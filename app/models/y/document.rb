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
  # can jump past a threshold).
  def append(bytes)
    row = updates.create!(payload: bytes)
    compact! if compaction_check?(row) && compaction_due?
  end

  # The merged document: state plus the whole tail. The tail is read first
  # and the snapshot re-read after it, both straight from the database: a
  # compaction committing between the two reads then hands us rows already
  # folded into the fresh snapshot, an idempotent double-apply, where
  # the reverse order could pair a pre-compaction snapshot with an empty
  # tail and omit committed changes. The parts are merged byte for byte
  # (Y.merge_updates), not through a Y::Doc, so everything stored comes
  # back, gaps included.
  def load_state
    snapshot, *tail = load_parts
    return snapshot if tail.empty?

    Y.merge_updates([snapshot, *tail].compact)
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
  # load_parts.
  def sync_state
    tail = updates.reset.pluck(:payload)
    Y.extend_state_vector(snapshot_state_vector || "".b, tail)
  end

  # What a client at state_vector is missing, as updates to send in order:
  # the snapshot's part, then the tail as stored. A client with nothing gets
  # the snapshot's bytes as they are; any other gets Y.diff_update of them,
  # which slices the encoded update without building a document and keeps
  # the whole delete set (a delete doesn't move a state vector, so a client
  # can lack one whatever its state vector says).
  def sync_diff(state_vector)
    tail = updates.reset.pluck(:payload)
    snapshot = self.class.where(id: id).pick(:state)
    snapshot = Y.diff_update(snapshot, state_vector) if snapshot && state_vector.bytesize > 1
    parts = [snapshot, *tail].compact
    parts.empty? ? [EMPTY_UPDATE] : parts
  end

  # Compact the tail into state: the snapshot and every row read, merged
  # byte for byte (Y.merge_updates), then exactly those rows deleted. The
  # row lock serializes racing compactions; a delta landing mid-compaction
  # isn't in `rows`, so it survives the delete and compacts next time.
  #
  # Nothing here asks what integrated. A merge keeps every struct and
  # delete of its inputs, gaps included, so no row can leave the table
  # before its content is in state. Routing rows through a Y::Doc and
  # keeping only what yrs reports as integrated can't promise that: yrs
  # doesn't always report a gap.
  def compact!
    with_lock do
      rows = updates.pluck(:id, :payload)
      next if rows.empty?

      write_state(Y.merge_updates([state, *rows.map(&:last)].compact))
      updates.where(id: rows.map(&:first)).delete_all
    end
  end

  private

  # The new snapshot, and its state vector where the column exists.
  def write_state(new_state)
    attributes = { state: new_state }
    attributes[:state_vector] = Y.state_vector_of(new_state) if self.class.stores_state_vector?
    update!(attributes)
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

  # Whether the tail has reached the compaction policy.
  def compaction_due?
    rows, bytes = updates.pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(LENGTH(payload)), 0)"))
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
