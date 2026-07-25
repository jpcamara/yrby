# frozen_string_literal: true

# A collaborative document: the identity a transport key points at, and the
# owner of its update log. Shaped like ActionText::RichText — an OPTIONAL
# polymorphic record + name binds a document to a Rails model (yrby-rails
# consumers such as lexxy-realtime use this); key-only documents (a room
# name, a UUID) leave them nil and live by `key` alone.
#
# materialized_at is for projections (rendered HTML, search text): the log
# version the projection was last built from, stamped by whatever builds it.
class Y::Document < ActiveRecord::Base
  self.table_name = "yrby_documents"

  belongs_to :record, polymorphic: true, optional: true
  has_many :updates, class_name: "Y::DocumentUpdate", dependent: :delete_all

  validates :key, presence: true
  before_validation :assign_default_key, on: :create

  class << self
    # The document bound to a record's attribute, created on first use.
    # Concurrent callers converge on one row via the (record, name) unique
    # index; the loser re-finds the winner's row, key included.
    def for(record, name)
      create_or_find_by!(record: record, name: name.to_s)
    end

    # The store contract for a sync channel, keyed by the transport key.
    def load_state(key)
      document = find_by(key: key)
      document && Y::DocumentUpdate.load(document.id)
    end

    def append(key, update)
      document = create_or_find_by!(key: key)
      Y::DocumentUpdate.append(document.id, update)
    end
  end

  private

  # Record-bound documents get a readable derived key (post/1/body); the
  # polymorphic record_type already holds the base_class name, so STI
  # subclasses derive the shared key for free. Namespaces keep their slash
  # (admin/post/1/body) — flattening would collide Admin::Post with
  # AdminPost. Key-only documents supply their own key, so this never
  # fires for them.
  def assign_default_key
    self.key ||= record_type && "#{record_type.underscore}/#{record_id}/#{name}"
  end
end
