# Active Storage's tables, from its install migration. Action Text's rich text
# declares `has_many_attached :embeds`, so Active Storage queries these
# tables. They stay empty: the site's storage service refuses every upload,
# and the records are read-only (config/initializers/no_uploads.rb).
class CreateActiveStorageTables < ActiveRecord::Migration[8.1]
  def change
    create_table :active_storage_blobs do |t|
      t.string   :key,          null: false
      t.string   :filename,     null: false
      t.string   :content_type
      t.text     :metadata
      t.string   :service_name, null: false
      t.bigint   :byte_size,    null: false
      t.string   :checksum
      t.datetime :created_at, null: false

      t.index [:key], unique: true
    end

    create_table :active_storage_attachments do |t|
      t.string     :name,     null: false
      t.references :record,   null: false, polymorphic: true, index: false
      t.references :blob,     null: false
      t.datetime   :created_at, null: false

      t.index %i[record_type record_id name blob_id], name: :index_active_storage_attachments_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end

    create_table :active_storage_variant_records do |t|
      t.belongs_to :blob, null: false, index: false
      t.string :variation_digest, null: false

      t.index %i[blob_id variation_digest], name: :index_active_storage_variant_records_uniqueness, unique: true
      t.foreign_key :active_storage_blobs, column: :blob_id
    end
  end
end
