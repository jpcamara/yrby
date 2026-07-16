# frozen_string_literal: true

# Durable storage for collaborative documents: an append-only update log
# with compaction. Appends are cheap and safe under concurrency (CRDT
# updates merge commutatively, so row order never matters). Compaction
# keeps loads fast by collapsing the log into one snapshot row once
# `compact_every` updates accumulate — without it, every load replays the
# document's full history.
class YrbyDocumentStore
  class << self
    # How many rows a document may accumulate before an append triggers
    # compaction inline. Raise it (or call compact! from a job instead) if
    # the inline count query ever shows up in a profile.
    attr_writer :compact_every

    def compact_every
      @compact_every ||= 500
    end

    # The merged state of a document, or nil if nothing was ever recorded.
    def load(key)
      payloads = YrbyDocumentUpdate.where(document_key: key).order(:id).pluck(:payload)
      return nil if payloads.empty?

      merge(payloads)
    end

    def append(key, update)
      YrbyDocumentUpdate.create!(document_key: key, payload: update)
      count = YrbyDocumentUpdate.where(document_key: key).count
      compact!(key) if (count % compact_every).zero?
    end

    # Collapse a document's rows into one snapshot row. Safe to run while
    # appends continue: only the rows read here are deleted, so an update
    # landing mid-compaction survives. Two racing compactions leave two
    # equivalent snapshots, which is harmless — merging is idempotent, and
    # the next compaction collapses them.
    def compact!(key)
      rows = YrbyDocumentUpdate.where(document_key: key).order(:id).pluck(:id, :payload)
      return if rows.size < 2

      snapshot = merge(rows.map(&:last))
      YrbyDocumentUpdate.transaction do
        YrbyDocumentUpdate.create!(document_key: key, payload: snapshot)
        YrbyDocumentUpdate.where(id: rows.map(&:first)).delete_all
      end
    end

    private

    # `compacted_state_update` (not `encode_state_as_update`) so a gappy
    # update recorded during a network wobble can never poison what gets
    # served to peers — pending structs must not cross the sync boundary.
    def merge(payloads)
      doc = Y::Doc.new
      payloads.each { |payload| doc.apply_update(payload) }
      doc.compacted_state_update
    end
  end
end
