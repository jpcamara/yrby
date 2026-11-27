# frozen_string_literal: true

# What `bin/rails generate yrby:tables` emits, minus the binary limits: those
# size MySQL's blob columns, and Postgres (this demo's database) rejects them
# — bytea is unbounded. Storage for the yrby-forms page's field-set documents
# (Y::Document + Y::DocumentUpdate); the editor pages keep using the demo's
# own Store, and the two coexist.
class CreateYTables < ActiveRecord::Migration[8.1]
  def change
    create_table :y_documents do |t|
      t.string :key, null: false, index: { unique: true }
      t.references :record, polymorphic: true, null: true, index: false
      t.string :name
      t.binary :state
      t.timestamps
      t.index %i[record_type record_id name], unique: true,
                                              where: "record_type IS NOT NULL",
                                              name: "index_y_documents_on_record_and_name"
    end

    create_table :y_document_updates do |t|
      t.references :document, null: false, foreign_key: { to_table: :y_documents }, index: false
      t.binary :payload, null: false
      t.boolean :pending, null: false, default: false
      t.datetime :created_at, null: false
      t.index %i[document_id pending]
    end
  end
end
