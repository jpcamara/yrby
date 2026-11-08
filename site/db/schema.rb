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

ActiveRecord::Schema[8.1].define(version: 2026_11_08_000003) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.string "name", null: false
    t.text "body"
    t.string "record_type", null: false
    t.integer "record_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.integer "record_id", null: false
    t.integer "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.integer "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "example_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "rooms", force: :cascade do |t|
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_rooms_on_slug", unique: true
  end

  create_table "seats", force: :cascade do |t|
    t.string "room_type", null: false
    t.integer "room_id", null: false
    t.string "name", null: false
    t.string "connection_id", null: false
    t.datetime "seen_at", null: false
    t.index ["connection_id"], name: "index_seats_on_connection_id"
    t.index ["room_type", "room_id", "name", "connection_id"], name: "index_seats_uniqueness", unique: true
    t.index ["seen_at"], name: "index_seats_on_seen_at"
  end

  create_table "y_document_updates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "document_id", null: false
    t.binary "payload", limit: 16777215, null: false
    t.boolean "pending", default: false, null: false
    t.index ["document_id", "pending"], name: "index_y_document_updates_on_document_id_and_pending"
  end

  create_table "y_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "name"
    t.integer "record_id"
    t.string "record_type"
    t.binary "state", limit: 1073741823
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_y_documents_on_key", unique: true
    t.index ["record_type", "record_id", "name"], name: "index_y_documents_on_record_and_name", unique: true, where: "record_type IS NOT NULL"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "y_document_updates", "y_documents", column: "document_id"
end
