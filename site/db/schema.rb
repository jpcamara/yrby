# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 20_260_831_000_002) do
  create_table "notes", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "room", null: false
    t.datetime "updated_at", null: false
    t.index ["room"], name: "index_notes_on_room", unique: true
  end

  create_table "y_document_updates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "document_id", null: false
    t.binary "payload", limit: 16_777_215, null: false
    t.boolean "pending", default: false, null: false
    t.index %w[document_id pending], name: "index_y_document_updates_on_document_id_and_pending"
  end

  create_table "y_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "name"
    t.integer "record_id"
    t.string "record_type"
    t.binary "state", limit: 1_073_741_823
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_y_documents_on_key", unique: true
    t.index %w[record_type record_id name], name: "index_y_documents_on_record_and_name", unique: true,
                                            where: "record_type IS NOT NULL"
  end

  add_foreign_key "y_document_updates", "y_documents", column: "document_id"
end
