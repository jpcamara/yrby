# frozen_string_literal: true

# ActionText's canonical table (from action_text:install): one rich-text body
# per (record, name). The Rhino page's CRDT-derived save lands here.
class CreateActionTextTables < ActiveRecord::Migration[8.1]
  def change
    create_table :action_text_rich_texts do |t|
      t.string     :name, null: false
      t.text       :body
      t.references :record, null: false, polymorphic: true, index: false

      t.timestamps

      t.index [:record_type, :record_id, :name],
              name: :index_action_text_rich_texts_uniqueness, unique: true
    end
  end
end
