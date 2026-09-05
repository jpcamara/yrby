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

  # How long the tail may grow before an append compacts it into state.
  # Lower values compact more often; higher values leave more tail rows
  # for each load to merge.
  class_attribute :compact_every, instance_writer: false, default: 64

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

    def append(key, update)
      (select(:id).find_by(key: key) || create_or_find_by!(key: key)).append(update)
    end

    private

    def adopt(record, name)
      document = find_by(key: derived_key(record, name), record_type: nil)
      document&.update!(record: record, name: name.to_s)
      document
    rescue ActiveRecord::RecordNotUnique
      find_by(record: record, name: name.to_s) # a racer adopted or created it first
    end

    def derived_key(record, name)
      # polymorphic_name is what Rails writes to record_type, so adoption
      # and assign_default_key derive the same string under any setting of
      # store_full_class_name.
      "#{record.class.polymorphic_name.underscore}/#{record.id}/#{name}"
    end
  end

  # Record one delta. The trigger is at-or-over rather than an exact
  # multiple (concurrent appends can jump past one) and counts only clean
  # rows: pending rows never satisfy it, so a quarantined gap doesn't
  # retrigger compaction on every append.
  def append(bytes)
    updates.create!(payload: bytes)
    compact! if updates.where(pending: false).count >= compact_every
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
    tail = updates.reset.pluck(:payload) # reset: never a cached tail
    snapshot = self.class.where(id: id).pick(:state)
    return snapshot if tail.empty?

    doc = Y::Doc.new
    doc.apply_update(snapshot) if snapshot
    tail.each { |payload| doc.apply_update(payload) }
    doc.encode_state_as_update
  end

  # Compact the tail into state. The row lock serializes racing
  # compactions; a delta landing mid-compaction isn't in `rows`, so it
  # survives the delete and compacts next time.
  #
  # A gapped batch still compacts everything integrable: the fold's
  # compacted_state_update captures every struct that integrates, so
  # rows independent of the gap land in state no matter how they
  # interleave with it. Only the gap tail survives as raw rows, judged
  # per row against the folded state: a row the new state could not
  # integrate cleanly carries the gap (or builds on it) and is
  # quarantined (marked pending); a row that is ready and adds nothing
  # is fully captured and deleted. An acked update never leaves the
  # table before its content is durably in state.
  def compact!
    with_lock do
      rows = updates.pluck(:id, :payload, :pending)
      next if rows.empty?
      next if compact_rows(rows)

      compact_around_gap(rows)
    end
  end

  private

  # The gapped-batch path: fold everything integrable into state, then
  # judge each row against the folded state. A row the folded state
  # cannot integrate cleanly carries the gap (or builds on it) and is
  # quarantined; a row that is ready and adds nothing is fully captured
  # and deleted.
  def compact_around_gap(rows)
    folded = Y::Doc.new
    folded.apply_update(state) if state
    rows.each { |_, payload, _| folded.apply_update(payload) }
    new_state = folded.compacted_state_update
    # Skip the write when nothing integrated beyond the current state
    # (compacted encoding is deterministic, so equal structs mean equal
    # bytes); a gap-only batch leaves state untouched.
    update!(state: new_state) unless new_state == (state || Y::Doc.new.compacted_state_update)

    base = Y::Doc.new
    base.apply_update(new_state)
    tail, captured = rows.partition do |_, payload, _|
      !base.update_ready?(payload) || base.update_advances?(payload)
    end
    updates.where(id: captured.map(&:first)).delete_all
    updates.where(id: tail.map(&:first)).update_all(pending: true)
  end

  # Compact state + the given rows if the merge is gap-free: writes state,
  # deletes the rows, returns true. Leaves everything untouched and returns
  # false on a gap.
  def compact_rows(rows) # rubocop:disable Naming/PredicateMethod -- compacts AND reports
    return true if rows.empty?

    doc = Y::Doc.new
    doc.apply_update(state) if state
    rows.each { |_, payload, _| doc.apply_update(payload) }
    return false if doc.pending?

    update!(state: doc.compacted_state_update)
    updates.where(id: rows.map(&:first)).delete_all
    true
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
