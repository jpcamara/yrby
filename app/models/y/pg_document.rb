# frozen_string_literal: true

# Y::Document with the Yjs work done inside Postgres by the pg_ydoc
# extension. Same load_state/append/compact! interface, plus the sync
# handshake answered in SQL, so serving a client never loads the document
# into Ruby. Choose it per attribute:
#
#   has_collaborative_document :body, store: :pg_ydoc
#
# It needs the extension (built from pg_ydoc/ in this repo), a ydoc state
# column, and SCHEMA below:
#
#   CREATE EXTENSION pg_ydoc;
#   ALTER TABLE y_documents ALTER COLUMN state TYPE ydoc USING ydoc(state);
#   -- then SCHEMA
#
# Writes append to its own log, y_document_log, which is insert-only.
# Compaction folds the log into the snapshot once the log's bytes reach a
# share of the snapshot's, and records the MVCC snapshot it folded under
# instead of deleting rows; reads skip rows that snapshot covers. The log
# has two partitions: rotation copies the rows of the older one that are
# not folded yet into the current one, truncates the older one, and makes
# it current. Nothing is ever deleted row by row, so the log leaves no dead
# tuples to vacuum. Rotation runs from append every rotate_log_every appends
# when no transaction is open, or call rotate_log! from a job.
#
# Serving a client never decodes the snapshot: the state vector is a stored
# column extended by the log, and the snapshot (as stored, for a client with
# nothing) and the log go out as two updates. A snapshot holding content
# past a gap has no stored state vector and is served merged instead.
#
# Fold tracking uses transaction ids, which mean nothing in another cluster.
# The log records the cluster's system identifier; on a cluster with a
# different one (a logical-replication cutover, say) compaction and
# rotation refuse to run until adopt_log! resets the tracking. A physical
# replica or a failover keeps the identifier and needs nothing.
class Y::PgDocument < Y::Document
  SCHEMA = <<~SQL
    ALTER TABLE y_documents
      ADD COLUMN state_vector bytea GENERATED ALWAYS AS (ydoc_state_vector(state, gapless => true)) STORED,
      ADD COLUMN folded pg_snapshot;
    CREATE TABLE y_document_log (
      document_id bigint NOT NULL,
      txid xid8 NOT NULL DEFAULT pg_current_xact_id(),
      slot smallint NOT NULL,
      payload bytea NOT NULL
    ) PARTITION BY LIST (slot);
    CREATE TABLE y_document_log_0 PARTITION OF y_document_log FOR VALUES IN (0);
    CREATE TABLE y_document_log_1 PARTITION OF y_document_log FOR VALUES IN (1);
    CREATE INDEX ON y_document_log (document_id, txid);
    CREATE TABLE y_document_log_slot (slot smallint NOT NULL, system_identifier bigint NOT NULL);
    INSERT INTO y_document_log_slot SELECT 0, system_identifier FROM pg_control_system();
  SQL

  # Log rows of document d not yet folded into its snapshot. The txid lower
  # bound is its own condition so the (document_id, txid) index skips folded
  # rows still waiting for their partition's truncate.
  UNFOLDED = <<~SQL.squish
    l.document_id = d.id AND l.txid >= coalesce(pg_snapshot_xmin(d.folded), '0'::xid8)
    AND (d.folded IS NULL OR NOT pg_visible_in_snapshot(l.txid, d.folded))
  SQL
  # The unfolded log of the outer row d, merged.
  LOG = "(SELECT ydoc_merge_agg(l.payload) FROM y_document_log l WHERE #{UNFOLDED})".freeze
  # The snapshot and the unfolded log, read in one statement, so one MVCC
  # snapshot sees both.
  MERGED = <<~SQL.freeze
    (SELECT ydoc_merge_agg(part) AS doc FROM (
       SELECT d.state::bytea AS part FROM y_documents d WHERE d.id = $1 AND d.state IS NOT NULL
       UNION ALL
       SELECT l.payload FROM y_documents d JOIN y_document_log l ON #{UNFOLDED} WHERE d.id = $1
     ) parts) merged
  SQL
  # True when the snapshot can be served without decoding it: there is none
  # yet, or it has a stored state vector (no gap).
  SPLIT = "(d.state IS NULL OR d.state_vector IS NOT NULL)"
  # True when the log's fold tracking belongs to this cluster.
  SAME_CLUSTER = <<~SQL.squish
    (SELECT s.system_identifier = c.system_identifier FROM y_document_log_slot s, pg_control_system() c)
  SQL

  # Compaction or rotation on a cluster the log's fold tracking doesn't
  # belong to. Run adopt_log!.
  class OtherCluster < StandardError
    def initialize = super("y_document_log was written by another cluster: run Y::PgDocument.adopt_log!")
  end

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

  # Insert, then two flags from the new row's txid. Compact: on about one
  # append in check_compaction_every, whether the unfolded log's bytes reach
  # the larger of compact_min_log_bytes and compact_log_ratio of the
  # snapshot's stored size. Rotate: on about one append in rotate_log_every.
  APPEND = <<~SQL.freeze
    WITH inserted AS (
      INSERT INTO y_document_log (document_id, slot, payload)
      VALUES ($1, (SELECT slot FROM y_document_log_slot), $2) RETURNING txid
    )
    SELECT (SELECT txid FROM inserted)::text::bigint % $3::int = 0
       AND (SELECT coalesce(sum(octet_length(l.payload)), 0) FROM y_documents d JOIN y_document_log l ON #{UNFOLDED}
             WHERE d.id = $1)
           >= greatest($4::bigint, $5::float8 * (SELECT coalesce(pg_column_size(state), 0) FROM y_documents WHERE id = $1)),
           (SELECT txid FROM inserted)::text::bigint % $6::int = 0
  SQL

  # Fold the unfolded log into the snapshot and record the statement's
  # snapshot as folded: every row it can see is in the new state. Rows that
  # commit later stay unfolded. A racing compaction waits on the row lock,
  # then re-reads against the new folded snapshot; if its own snapshot is
  # older, some rows read as unfolded again and are merged twice, which
  # changes nothing.
  COMPACT = <<~SQL.freeze
    UPDATE y_documents d
       SET state = ydoc_apply(d.state, #{LOG}::bytea), folded = pg_current_snapshot(), updated_at = now()
     WHERE d.id = $1 AND #{SAME_CLUSTER}
    RETURNING true
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
  # Rotation: attempted on about one append in rotate_log_every, waiting at
  # most rotate_lock_timeout for readers and writers of the older partition.
  class_attribute :rotate_log_every, instance_writer: false, default: 4096
  class_attribute :rotate_lock_timeout, instance_writer: false, default: "50ms"

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

    # Copy the older partition's unfolded rows into the current one, truncate
    # it, and make it current. The lock waits for writers still in the older
    # partition, so none of their rows are missed. Rows of deleted documents
    # are dropped. Returns false without doing anything inside an open
    # transaction (the lock would be held until it ends) or when the lock
    # isn't granted within rotate_lock_timeout.
    def rotate_log!
      connection_pool.with_connection do |c|
        next false if c.transaction_open?

        c.transaction do
          c.execute("SET LOCAL lock_timeout = #{c.quote(rotate_lock_timeout)}")
          raise OtherCluster unless c.select_value("SELECT #{SAME_CLUSTER}")

          slot = c.select_value("SELECT slot FROM y_document_log_slot FOR UPDATE").to_i
          older = 1 - slot
          c.execute("LOCK TABLE y_document_log_#{older} IN ACCESS EXCLUSIVE MODE")
          c.execute(<<~SQL)
            INSERT INTO y_document_log (document_id, txid, slot, payload)
            SELECT l.document_id, l.txid, #{slot}, l.payload
              FROM y_document_log_#{older} l JOIN y_documents d ON #{UNFOLDED}
          SQL
          c.execute("TRUNCATE y_document_log_#{older}")
          c.execute("UPDATE y_document_log_slot SET slot = #{older}")
        end
        true
      rescue ActiveRecord::LockWaitTimeout
        false
      end
    end

    # After moving to a cluster with another system identifier: give every
    # log row this transaction's id and forget every folded snapshot, so all
    # of the log reads as unfolded (merging rows already in a snapshot again
    # changes nothing) and the next compaction folds it in this cluster.
    def adopt_log!
      connection_pool.with_connection do |c|
        c.transaction do
          c.execute("LOCK TABLE y_document_log IN ACCESS EXCLUSIVE MODE")
          c.execute("UPDATE y_document_log SET txid = pg_current_xact_id()")
          c.execute("UPDATE y_documents SET folded = NULL WHERE folded IS NOT NULL")
          c.execute(<<~SQL)
            UPDATE y_document_log_slot SET system_identifier = (SELECT system_identifier FROM pg_control_system())
          SQL
        end
      end
    end
  end

  def load_state = select_one(LOAD, id).first

  def append(bytes)
    compact_due, rotate_due = select_one(
      APPEND, id, bytes, check_compaction_every, compact_min_log_bytes, compact_log_ratio, rotate_log_every,
      binary: false
    )
    compact! if truthy?(compact_due)
    self.class.rotate_log! if truthy?(rotate_due)
  end

  def compact!
    if select_one(COMPACT, id).empty? && !self.class.connection.select_value("SELECT #{SAME_CLUSTER}")
      raise OtherCluster
    end

    nil
  end

  def sync_state = select_one(SYNC_STATE, id).first

  def sync_diff(state_vector)
    first, log = select_one(SYNC_DIFF, id, state_vector)
    log.nil? || log == EMPTY_UPDATE ? first : [first, log]
  end

  private

  # A boolean result, decoded or as text depending on the connection's type map.
  def truthy?(value) = [true, "t"].include?(value)

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
