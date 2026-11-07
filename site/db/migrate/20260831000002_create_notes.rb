# frozen_string_literal: true

# The record behind the Rich text (Lexxy) demo. There's one Note per room, and
# it stores the rendered HTML in a plain column (the app has no Action Text).
# The CRDT state is in y_documents, linked to the note polymorphically.
class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.string :room, null: false, index: { unique: true }
      t.text :body
      t.timestamps
    end
  end
end
