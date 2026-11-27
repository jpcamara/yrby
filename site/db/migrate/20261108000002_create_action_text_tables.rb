# Action Text's table, from its install migration. A room's body is a row
# here (has_collaborative_rich_text declares has_rich_text).
class CreateActionTextTables < ActiveRecord::Migration[8.1]
  def change
    create_table :action_text_rich_texts do |t|
      t.string     :name, null: false
      t.text       :body
      t.references :record, null: false, polymorphic: true, index: false
      t.timestamps

      t.index %i[record_type record_id name], name: "index_action_text_rich_texts_uniqueness", unique: true
    end
  end
end
