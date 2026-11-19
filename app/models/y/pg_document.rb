# frozen_string_literal: true

# Y::Document with the Yjs work done inside Postgres by the pg_ydoc
# extension. Same tables and the same load_state/append/compact! interface,
# plus the sync handshake answered in SQL, so serving a client never loads
# the document into Ruby. Choose it per attribute:
#
#   has_collaborative_document :body, store: :pg_ydoc
#
# It needs the extension (built from pg_ydoc/ in this repo), a ydoc state
# column, and the snapshot's state vector stored beside it:
#
#   CREATE EXTENSION pg_ydoc;
#   ALTER TABLE y_documents ALTER COLUMN state TYPE ydoc USING ydoc(state);
#   ALTER TABLE y_documents ADD COLUMN state_vector bytea
#     GENERATED ALWAYS AS (ydoc_state_vector(state, gapless => true)) STORED;
#
# Writes append to the log; compaction folds the log into the snapshot once
# the log's bytes reach a share of the snapshot's, so a large document is
# rewritten rarely. Serving a client never decodes the snapshot: the state
# vector is the stored one extended by the log, and the snapshot (as stored,
# for a client with nothing) and the log go out as two updates. A snapshot
# holding content past a gap has no stored state vector and is served
# merged instead.
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
  LOG = "(SELECT ydoc_merge_agg(payload) FROM y_document_updates WHERE document_id = $1)"
  # True when the snapshot can be served without decoding it: there is none
  # yet, or it has a stored state vector (no gap).
  SPLIT = "(d.state IS NULL OR d.state_vector IS NOT NULL)"

  LOAD = "SELECT doc::bytea FROM #{MERGED}".freeze
  SYNC_STATE = <<~SQL.freeze
    SELECT CASE WHEN #{SPLIT} THEN ydoc_extend_state_vector(d.state_vector, #{LOG})
                ELSE (SELECT ydoc_state_vector(doc) FROM #{MERGED}) END
      FROM y_documents d WHERE d.id = $1
  SQL
  # The snapshot's part, then the log's part (NULL when it is served merged).
  SYNC_DIFF = <<~SQL.freeze
    SELECT CASE WHEN #{SPLIT} THEN coalesce(ydoc_diff(d.state, $2, true), ydoc()::bytea)
                ELSE (SELECT ydoc_diff(coalesce(doc, ydoc()), $2, true) FROM #{MERGED}) END,
           CASE WHEN #{SPLIT} THEN ydoc_diff(#{LOG}, $2, true) END
      FROM y_documents d WHERE d.id = $1
  SQL

  # Insert, and on one append in check_compaction_every (by the new row's
  # id), say whether the log has grown enough to compact: its bytes against
  # the larger of compact_min_log_bytes and compact_log_ratio of the
  # snapshot's stored size. The sum's snapshot predates the insert.
  APPEND = <<~SQL
    WITH inserted AS (
      INSERT INTO y_document_updates (document_id, payload, created_at) VALUES ($1, $2, now()) RETURNING id
    )
    SELECT (SELECT id FROM inserted) % $3::int = 0
       AND (SELECT coalesce(sum(octet_length(payload)), 0) FROM y_document_updates WHERE document_id = $1)
           >= greatest($4::bigint, $5::float8 * (SELECT coalesce(pg_column_size(state), 0) FROM y_documents WHERE id = $1))
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

  # Compaction policy (compact_every doesn't apply here). The log compacts
  # when its bytes reach compact_log_ratio of the snapshot's stored size, or
  # compact_min_log_bytes for a small one, checked on about one append in
  # check_compaction_every so an append doesn't sum the log each time.
  class_attribute :compact_log_ratio, instance_writer: false, default: 0.1
  class_attribute :compact_min_log_bytes, instance_writer: false, default: 4096
  class_attribute :check_compaction_every, instance_writer: false, default: 16

  class << self
    # The state vector for the server's SyncStep1. Takes a row (or nil before
    # the first write), as Y::Collaborative::Attribute holds one.
    def sync_state_of(row) = row ? row.sync_state : EMPTY_STATE_VECTOR

    # What a client at state_vector is missing, pending content included: one
    # update, or several to send in order.
    def sync_diff_of(row, state_vector) = row ? row.sync_diff(state_vector) : EMPTY_UPDATE

    # The same, by key, for a channel that addresses documents by key.
    def sync_state(key) = sync_state_of(select(:id).find_by(key: key))
    def sync_diff(key, state_vector) = sync_diff_of(select(:id).find_by(key: key), state_vector)
  end

  def load_state = select_one(LOAD, id).first

  def append(bytes)
    due = select_one(APPEND, id, bytes, check_compaction_every, compact_min_log_bytes, compact_log_ratio,
                     binary: false).first
    compact! if [true, "t"].include?(due) # decoded or text, per the connection's type map
  end

  def compact!
    select_one(COMPACT, id)
    nil
  end

  def sync_state = select_one(SYNC_STATE, id).first

  def sync_diff(state_vector)
    first, log = select_one(SYNC_DIFF, id, state_vector)
    log.nil? || log == EMPTY_UPDATE ? first : [first, log]
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
