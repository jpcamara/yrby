# frozen_string_literal: true

require "base64"

# A PostgreSQL-backed durable store for document changes, closer to what you'd
# run in production than the file store. Each `record` is a committed INSERT,
# durable in the WAL before it returns. Postgres group-commits concurrent
# transactions, so many processes recording at once can share fsyncs instead of
# serializing the way a per-file store does. The bigserial `id` gives the total
# order of changes.
module PgStore
  module_function

  INSERT_SQL = "INSERT INTO document_changes (doc_key, delta) VALUES ($1, $2)"

  # Synchronously persist a change. Returns only after the row is committed
  # (synchronous_commit=on). Raising rejects the change, and yrby won't
  # apply or relay it. This uses a raw parameterized INSERT with a binary bytea
  # bind to skip the per-change cost of an AR model; concurrent commits from the
  # RPC worker threads group-commit in Postgres.
  def record(key, update)
    Fault.simulate(key)
    DocumentChange.connection.raw_connection.exec_params(
      INSERT_SQL, [key, { value: binary(update), type: 17, format: 1 }]
    )
  end

  # Rebuild the document by replaying every recorded delta in id order.
  # Returns a single merged Y.js update, or nil for an unknown document.
  def replay(key)
    updates = DocumentChange.where(doc_key: key).order(:id).pluck(:delta)
    return nil if updates.empty?

    doc = Y::Doc.new
    updates.each do |u|
      doc.apply_update(binary(u))
    rescue StandardError
      next # skip a corrupt row rather than failing the whole rebuild
    end
    doc.encode_state_as_update
  end

  # A version for the document that is monotonic in visibility order: the
  # count of committed rows. MAX(id) is not safe here. Ids are assigned at
  # INSERT but rows become visible at COMMIT, and those orders differ under
  # concurrency: a slow commit with a lower id can land after a reader has
  # stamped a higher MAX, and the staleness check would never see it. A
  # late commit still increases the count, so the next read detects it
  # (see NoteMaterializer). Returns 0 for an unknown document. The count is
  # an index-only scan on [doc_key, id].
  def version(key)
    DocumentChange.where(doc_key: key).count
  end

  # Base64 deltas (for the /audit endpoint). Count reflects stored rows.
  def entries(key)
    DocumentChange.where(doc_key: key).order(:id).pluck(:delta).map { |u| Base64.strict_encode64(binary(u)) }
  end

  def reset!(key)
    DocumentChange.where(doc_key: key).delete_all
    Fault.reset!(key)
  end

  def binary(str)
    str.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
  end
end
