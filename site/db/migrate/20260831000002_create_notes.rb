# frozen_string_literal: true

# The record behind the Rich text (Lexxy) demo: one Note per room, holding the
# materialized HTML in a plain column (no Action Text). The collaborative CRDT
# state lives in y_documents, bound to the note polymorphically.
class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.string :room, null: false, index: { unique: true }
      t.text :body
      t.timestamps
    end
  end
end
