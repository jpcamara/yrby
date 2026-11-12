# frozen_string_literal: true

# Experimental: Y::Document with the Yjs work done inside Postgres by the
# pg_yrby extension. Same tables and the same load_state/append/compact!
# interface, so a channel can use it in place of Y::Document.
#
# Needs CREATE EXTENSION pg_yrby and y_documents.state as a ydoc:
#
#   ALTER TABLE y_documents ALTER COLUMN state TYPE ydoc USING ydoc(state);
#
# The pending column goes unused: a gapped update waits inside the snapshot
# (ydoc keeps pending content and never serves it in a diff), so compaction
# folds and deletes every row it reads.
class Y::PgDocument < Y::Document
  # The snapshot and the whole log as update rows. Read in one statement,
  # which sees one MVCC snapshot, so a compaction committing meanwhile can't
  # hide rows (Y::Document reads the tail first and the snapshot second for
  # the same reason).
  PARTS = <<~SQL
    (SELECT state::bytea AS part FROM y_documents WHERE id = $1 AND state IS NOT NULL
     UNION ALL
     SELECT payload FROM y_document_updates WHERE document_id = $1) parts
  SQL
  LOAD = "SELECT ydoc_merge_agg(part)::bytea FROM #{PARTS}".freeze

  # Insert, and count the log in the same round trip. The count's snapshot
  # predates the insert, hence the + 1.
  APPEND = <<~SQL
    WITH inserted AS (
      INSERT INTO y_document_updates (document_id, payload, created_at) VALUES ($1, $2, now())
    )
    SELECT count(*) + 1 FROM y_document_updates WHERE document_id = $1
  SQL

  # Fold the log into the snapshot and delete it, atomically. Concurrent
  # appends that commit after the DELETE's snapshot stay for next time.
  COMPACT = <<~SQL
    WITH folded AS (DELETE FROM y_document_updates WHERE document_id = $1 RETURNING payload)
    UPDATE y_documents
       SET state = ydoc_apply(state, (SELECT ydoc_merge_agg(payload)::bytea FROM folded)),
           updated_at = now()
     WHERE id = $1
  SQL

  # Sync step 1 and 2 without loading the document into Ruby.
  STATE_VECTOR = "SELECT ydoc_state_vector(ydoc_merge_agg(part)) FROM #{PARTS}".freeze
  DIFF = "SELECT ydoc_diff(ydoc_merge_agg(part), $2) FROM #{PARTS}".freeze

  def load_state = query(LOAD, id)

  def append(bytes)
    count = query(APPEND, id, bytes, binary: false).to_i
    compact! if count >= compact_every
  end

  def compact!
    query(COMPACT, id)
    nil
  end

  # What a client with state vector sv is missing (sync step 2), without
  # pending content. sv nil means the whole document.
  def diff(sv = nil) = query(DIFF, id, sv)

  # The server's state vector (sync step 1).
  def state_vector = query(STATE_VECTOR, id)

  private

  def query(sql, *params, binary: true)
    params = params.map do |v|
      v.is_a?(String) ? { value: v, type: 17, format: 1 } : { value: v&.to_s, format: 0 }
    end
    result = self.class.connection.raw_connection.exec_params(sql, params, binary ? 1 : 0)
    value = result.ntuples.zero? ? nil : result.getvalue(0, 0)
    value&.force_encoding(Encoding::BINARY) if binary
    value
  end
end
