# frozen_string_literal: true

# One rich-text note per collaborative document and fragment: where the
# CRDT-derived ActionText content is persisted (the body itself lives in
# action_text_rich_texts via has_rich_text). The Rhino page materializes
# the "rhino" fragment and the Lexxy page "root"; see NoteMaterializer.
class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes do |t|
      t.string :document_id, null: false
      t.string :fragment, null: false
      t.timestamps

      t.index %i[document_id fragment], unique: true
    end
  end
end
