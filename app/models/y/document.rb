# frozen_string_literal: true

# One row per collaborative document. `key` addresses it on the transport;
# `state` holds the merged snapshot, and the update rows are only the
# uncompacted tail — so loading is one row read plus a short, bounded tail,
# whatever the document's history. An optional polymorphic record + name
# binds it to a Rails model, like ActionText::RichText; key-only documents
# (a room name, a UUID) leave both nil.
#
# changed_at: when content last changed (folding is a representation change
# and does not move it). materialized_at: when a projection (rendered HTML,
# search text) was last built from the document, stamped by whatever builds
# the projection. A projection is stale when changed_at is newer.
class Y::Document < ActiveRecord::Base
  self.table_name = "y_documents"

  belongs_to :record, polymorphic: true, optional: true
  has_many :updates, class_name: "Y::DocumentUpdate", dependent: :delete_all

  validates :key, presence: true
  # The legal shapes are exactly two — key-only, or key + record + name.
  # Column checks, not the association: reading `record` constantizes
  # record_type, which must not be a validity requirement.
  validates :name, presence: true, if: :record_type
  validates :record_type, presence: true, if: :name
  validates :record_id, presence: true, if: :record_type
  before_validation :assign_default_key, on: :create

  # How long the tail may grow before an append folds it into state. Small,
  # because loads read state directly: the threshold tunes write
  # amplification against tail length, not load latency.
  class_attribute :fold_every, instance_writer: false, default: 64

  class << self
    def locate(key) = find_by(key: key)

    def locate!(key)
      find_by(key: key) || create_or_find_by!(key: key)
    end

    # The document bound to a record's attribute, created on first use.
    # Find first (after the first call, every call is a read), then adopt:
    # if a channel already appended under the key this binding derives, a
    # key-only row exists whose key is taken — claiming it converges the two
    # identities where a plain insert would collide on the key index.
    def for(record, name)
      find_by(record: record, name: name.to_s) ||
        adopt(record, name) ||
        create_or_find_by!(record: record, name: name.to_s)
    end

    # The store contract for a sync channel, keyed by the transport key.
    def load_state(key) = locate(key)&.load_state

    def append(key, update)
      locate!(key).append(update)
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
      "#{record.class.base_class.name.underscore}/#{record.id}/#{name}"
    end
  end

  # Record one delta. The tail count that triggers folding is at-or-over,
  # not an exact multiple (concurrent appends can jump past a multiple), and
  # counts only clean rows, so a quarantined gap can't hold it over the
  # threshold forever.
  def append(bytes)
    updates.create!(payload: bytes)
    touch(:changed_at)
    fold! if updates.where(pending: false).count >= fold_every
  end

  # The merged document: state plus the whole tail. Quarantined rows are
  # applied too — the output goes through compacted_state_update, which is
  # gap-free by construction, so an unhealed gap contributes nothing while a
  # gap healed by a newer tail row is served immediately instead of waiting
  # for the next fold.
  def load_state
    tail = updates.pluck(:payload)
    return state if tail.empty?

    doc = Y::Doc.new
    doc.apply_update(state) if state
    tail.each { |payload| doc.apply_update(payload) }
    doc.compacted_state_update
  end

  # Fold the tail into state. The row lock serializes racing folds; appends
  # only insert child rows (plus a changed_at touch that briefly queues
  # behind the lock), and a delta landing mid-fold isn't in `rows`, so it
  # survives the delete and folds next time.
  #
  # A causally-gapped batch is never folded whole and never deleted — state
  # would silently exclude the gap, destroying the only healable copy. Two
  # stages bound the damage: if the clean rows alone fold cleanly, they fold
  # and only the gap stays quarantined; rows that causally build on
  # quarantined content quarantine with it.
  def fold!
    with_lock do
      rows = updates.pluck(:id, :payload, :pending)
      next if rows.empty?

      unless fold_rows(rows)
        clean = rows.reject { |_, _, pending| pending }
        remainder = fold_rows(clean) ? rows - clean : rows
        updates.where(id: remainder.map(&:first)).update_all(pending: true)
      end
    end
  end

  private

  # Fold state + the given rows if the merge is gap-free: writes state,
  # deletes the rows, returns true. Leaves everything untouched and returns
  # false on a gap. changed_at is deliberately not moved — folding is not a
  # content change, and projections stamped before it stay fresh.
  def fold_rows(rows) # rubocop:disable Naming/PredicateMethod -- folds AND reports
    return true if rows.empty?

    doc = Y::Doc.new
    doc.apply_update(state) if state
    rows.each { |_, payload, _| doc.apply_update(payload) }
    return false if doc.pending?

    update!(state: doc.compacted_state_update)
    updates.where(id: rows.map(&:first)).delete_all
    true
  end

  # Derives post/1/body from the polymorphic record_type — the base_class
  # name, so STI subclasses share a key. Namespaces keep their slash
  # (admin/post/1/body); flattening would collide Admin::Post with
  # AdminPost. record_id is nil for an unsaved record at validation time
  # (autosave runs after), so it guards too. Key-only documents supply
  # their own key.
  def assign_default_key
    self.key ||= record_type && record_id && "#{record_type.underscore}/#{record_id}/#{name}"
  end
end
