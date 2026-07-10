# frozen_string_literal: true

# One saved rich-text note per collaborative document: where the Rhino page's
# CRDT-derived ActionText snapshot is persisted (the body itself lives in
# action_text_rich_texts via has_rich_text).
class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.string :document_id, null: false
      t.timestamps

      t.index :document_id, unique: true
    end
  end
end
