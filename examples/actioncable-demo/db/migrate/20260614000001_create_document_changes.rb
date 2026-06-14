# frozen_string_literal: true

class CreateDocumentChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :document_changes do |t|
      t.string :doc_key, null: false
      t.binary :delta, null: false           # one CRDT update delta (bytea)
      t.datetime :created_at, null: false, default: -> { "now()" }
    end
    # The bigserial primary key is the authoritative total order of changes.
    add_index :document_changes, %i[doc_key id]
  end
end
