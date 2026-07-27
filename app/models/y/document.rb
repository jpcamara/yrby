# frozen_string_literal: true

# One row per collaborative document. `key` addresses it on the transport;
# the update log holds its edits. An optional polymorphic record + name
# binds it to a Rails model, like ActionText::RichText; key-only documents
# (a room name, a UUID) leave both nil.
#
# materialized_at: when a projection (rendered HTML, search text) was last
# built from the log. Stamped by whatever builds the projection.
class Y::Document < ActiveRecord::Base
  self.table_name = "y_documents"

  belongs_to :record, polymorphic: true, optional: true
  has_many :updates, class_name: "Y::DocumentUpdate", dependent: :delete_all

  validates :key, presence: true
  before_validation :assign_default_key, on: :create

  class << self
    # The document bound to a record's attribute, created on first use.
    # Find first: create_or_find_by! is insert-first, and after the first
    # call the row exists, so the common path would be a doomed INSERT and a
    # rescue. Concurrent creators still converge on one row via the
    # (record, name) unique index; the loser re-finds the winner's row, key
    # included.
    def for(record, name)
      find_by(record: record, name: name.to_s) ||
        create_or_find_by!(record: record, name: name.to_s)
    end

    # The store contract for a sync channel, keyed by the transport key.
    def load_state(key)
      document = find_by(key: key)
      document && Y::DocumentUpdate.load(document.id)
    end

    # Find first, as in .for — this runs on every recorded change.
    def append(key, update)
      document = find_by(key: key) || create_or_find_by!(key: key)
      Y::DocumentUpdate.append(document.id, update)
    end
  end

  private

  # Derives post/1/body from the polymorphic record_type — the base_class
  # name, so STI subclasses share a key. Namespaces keep their slash
  # (admin/post/1/body); flattening would collide Admin::Post with
  # AdminPost. Key-only documents supply their own key. record_id is nil
  # until an unsaved record autosaves — after validation — so it guards too,
  # or the key would derive malformed ("page//body").
  def assign_default_key
    self.key ||= record_type && record_id && "#{record_type.underscore}/#{record_id}/#{name}"
  end
end
