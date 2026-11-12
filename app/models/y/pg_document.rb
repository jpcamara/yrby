# frozen_string_literal: true

# Y::Document with the Yjs work done inside Postgres by the pg_yrby
# extension. Same tables and the same load_state/append/compact! interface,
# plus the sync handshake answered in SQL, so serving a client never loads
# the document into Ruby. Choose it per attribute:
#
#   has_collaborative_document :body, store: :pg_yrby
#
# It needs the extension and a ydoc state column:
#
#   CREATE EXTENSION pg_yrby;
#   ALTER TABLE y_documents ALTER COLUMN state TYPE ydoc USING ydoc(state);
#
# The pending column goes unused. A gapped update waits inside the snapshot,
# which keeps pending content, so compaction folds and deletes every row it
# reads. A joining client is still sent the pending content, as with
# Y::Document, so it heals when the missing update arrives.
class Y::PgDocument < Y::Document
  # The snapshot and the whole log, read in one statement. One statement sees
  # one MVCC snapshot, so a compaction committing meanwhile can't hide rows
  # (Y::Document reads the tail first and the snapshot second for the same
  # reason).
  MERGED = <<~SQL
    (SELECT ydoc_merge_agg(part) AS doc FROM (
       SELECT state::bytea AS part FROM y_documents WHERE id = $1 AND state IS NOT NULL
       UNION ALL
       SELECT payload FROM y_document_updates WHERE document_id = $1
     ) parts) merged
  SQL

  LOAD = "SELECT doc::bytea FROM #{MERGED}".freeze
  SYNC_STATE = <<~SQL.freeze
    SELECT ydoc_state_vector(coalesce(doc, ydoc())), coalesce(ydoc_has_pending(doc), false)
      FROM #{MERGED}
  SQL
  SYNC_DIFF = <<~SQL.freeze
    SELECT ydoc_diff(coalesce(doc, ydoc()), $2, include_pending => true), coalesce(ydoc_has_pending(doc), false)
      FROM #{MERGED}
  SQL

  # Insert, and count the log in the same round trip. The count's snapshot
  # predates the insert, hence the + 1.
  APPEND = <<~SQL
    WITH inserted AS (
      INSERT INTO y_document_updates (document_id, payload, created_at) VALUES ($1, $2, now())
    )
    SELECT count(*) + 1 FROM y_document_updates WHERE document_id = $1
  SQL

  # Fold the log into the snapshot and delete it, atomically. Appends that
  # commit after the DELETE's snapshot stay for the next compaction, and a
  # racing compaction waits on the row locks and then folds nothing twice.
  COMPACT = <<~SQL
    WITH folded AS (DELETE FROM y_document_updates WHERE document_id = $1 RETURNING payload)
    UPDATE y_documents
       SET state = ydoc_apply(state, (SELECT ydoc_merge_agg(payload)::bytea FROM folded)),
           updated_at = now()
     WHERE id = $1
  SQL

  # The handshake for a document that doesn't exist yet: an empty state
  # vector, and nothing to send.
  EMPTY_STATE_VECTOR = "\x00".b.freeze
  EMPTY_UPDATE = "\x00\x00".b.freeze

  class << self
    # [state_vector, pending] for the server's SyncStep1. Takes a row (or
    # nil before the first write), as Y::Collaborative::Attribute holds one.
    def sync_state_of(row) = row ? row.sync_state : [EMPTY_STATE_VECTOR, false]

    # [update, pending]: what a client at state_vector is missing, pending
    # content included.
    def sync_diff_of(row, state_vector) = row ? row.sync_diff(state_vector) : [EMPTY_UPDATE, false]

    # The same, by key, for a channel that addresses documents by key.
    def sync_state(key) = sync_state_of(select(:id).find_by(key: key))
    def sync_diff(key, state_vector) = sync_diff_of(select(:id).find_by(key: key), state_vector)
  end

  def load_state = select_one(LOAD, id).first

  def append(bytes)
    count = select_one(APPEND, id, bytes, binary: false).first.to_i
    compact! if count >= compact_every
  end

  def compact!
    select_one(COMPACT, id)
    nil
  end

  def sync_state
    sv, pending = select_one(SYNC_STATE, id)
    [sv, pending == "\x01".b]
  end

  def sync_diff(state_vector)
    update, pending = select_one(SYNC_DIFF, id, state_vector)
    [update, pending == "\x01".b]
  end

  private

  # One row through the raw connection, with bytea parameters and results
  # in binary, so documents never round-trip through hex.
  def select_one(sql, *params, binary: true)
    params = params.map do |v|
      v.is_a?(String) ? { value: v, type: 17, format: 1 } : { value: v&.to_s, format: 0 }
    end
    self.class.connection_pool.with_connection do |connection|
      # Send any BEGIN Active Record is holding back, so these statements
      # join the caller's transaction.
      connection.materialize_transactions
      result = connection.raw_connection.exec_params(sql, params, binary ? 1 : 0)
      next [] if result.ntuples.zero?

      Array.new(result.nfields) do |i|
        value = result.getvalue(0, i)
        value.is_a?(String) && binary ? value.b : value
      end
    end
  end
end
