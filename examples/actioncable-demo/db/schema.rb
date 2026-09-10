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

ActiveRecord::Schema[8.1].define(version: 2026_08_26_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "document_changes", force: :cascade do |t|
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.binary "delta", null: false
    t.string "doc_key", null: false
    t.index ["doc_key", "id"], name: "index_document_changes_on_doc_key_and_id"
  end

  create_table "notes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "document_id", null: false
    t.string "fragment", null: false
    t.bigint "through_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["document_id", "fragment"], name: "index_notes_on_document_id_and_fragment", unique: true
  end

  create_table "tickets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.date "due_on"
    t.integer "priority"
    t.string "status", default: "triage", null: false
    t.string "summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "urgent"
  end

  create_table "y_document_updates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "document_id", null: false
    t.binary "payload", null: false
    t.boolean "pending", default: false, null: false
    t.index ["document_id", "pending"], name: "index_y_document_updates_on_document_id_and_pending"
  end

  create_table "y_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "name"
    t.bigint "record_id"
    t.string "record_type"
    t.binary "state"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_y_documents_on_key", unique: true
    t.index ["record_type", "record_id", "name"], name: "index_y_documents_on_record_and_name", unique: true, where: "(record_type IS NOT NULL)"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "y_document_updates", "y_documents", column: "document_id"
end
