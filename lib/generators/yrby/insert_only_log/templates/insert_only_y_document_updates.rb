# frozen_string_literal: true

# y_document_updates as an insert-only log in two partitions (Postgres 13+).
# Each row records the transaction that wrote it (txid); y_documents.folded
# records the snapshot each compaction read the log under. The slot table
# holds the partition new rows go to and the cluster's system identifier,
# which the transaction ids belong to.
class InsertOnlyYDocumentUpdates < ActiveRecord::Migration<%= migration_version %>
  def up
    execute <<~SQL
      ALTER TABLE y_documents ADD COLUMN folded pg_snapshot;

      CREATE TABLE y_document_updates_slot (slot smallint NOT NULL, system_identifier bigint NOT NULL);
      INSERT INTO y_document_updates_slot SELECT 0, system_identifier FROM pg_control_system();
      CREATE FUNCTION y_document_updates_slot() RETURNS smallint LANGUAGE sql STABLE
        AS 'SELECT slot FROM y_document_updates_slot';

      ALTER TABLE y_document_updates RENAME TO y_document_updates_before_log;
      CREATE TABLE y_document_updates (
        id bigint NOT NULL DEFAULT nextval('y_document_updates_id_seq'),
        document_id bigint NOT NULL REFERENCES y_documents,
        payload bytea NOT NULL,
        created_at timestamp(6) NOT NULL,
        txid xid8 NOT NULL DEFAULT pg_current_xact_id(),
        slot smallint NOT NULL DEFAULT y_document_updates_slot()
      ) PARTITION BY LIST (slot);
      CREATE TABLE y_document_updates_0 PARTITION OF y_document_updates FOR VALUES IN (0);
      CREATE TABLE y_document_updates_1 PARTITION OF y_document_updates FOR VALUES IN (1);
      CREATE INDEX index_y_document_updates_on_document_id_and_txid ON y_document_updates (document_id, txid);

      INSERT INTO y_document_updates (id, document_id, payload, created_at)
        SELECT id, document_id, payload, created_at FROM y_document_updates_before_log;
      ALTER SEQUENCE y_document_updates_id_seq OWNED BY y_document_updates.id;
      DROP TABLE y_document_updates_before_log;
    SQL
  end

  # Back to a plain table holding the rows not folded yet.
  def down
    execute <<~SQL
      CREATE TABLE y_document_updates_plain (
        id bigint PRIMARY KEY DEFAULT nextval('y_document_updates_id_seq'),
        document_id bigint NOT NULL REFERENCES y_documents,
        payload bytea NOT NULL,
        created_at timestamp(6) NOT NULL
      );
      INSERT INTO y_document_updates_plain (id, document_id, payload, created_at)
        SELECT l.id, l.document_id, l.payload, l.created_at
          FROM y_document_updates l JOIN y_documents d ON d.id = l.document_id
         WHERE d.folded IS NULL OR NOT pg_visible_in_snapshot(l.txid, d.folded);
      ALTER SEQUENCE y_document_updates_id_seq OWNED BY y_document_updates_plain.id;
      DROP TABLE y_document_updates;
      ALTER TABLE y_document_updates_plain RENAME TO y_document_updates;
      CREATE INDEX index_y_document_updates_on_document_id ON y_document_updates (document_id);
      DROP FUNCTION y_document_updates_slot();
      DROP TABLE y_document_updates_slot;
      ALTER TABLE y_documents DROP COLUMN folded;
    SQL
  end
end
