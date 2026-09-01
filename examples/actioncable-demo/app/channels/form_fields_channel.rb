# frozen_string_literal: true

# What `bin/rails generate yrby_forms:install` emits, with authorized?
# opened up for the demo (no users). Syncs clients with a record's
# collaborative field set; after storing each update, the declared columns
# are refreshed from the full document.
class FormFieldsChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |_key| record.find_or_create_collaborative_fields_document.load_state }
  on_change do |key, update|
    record.find_or_create_collaborative_fields_document.append(update)
    begin
      record.refresh_collaborative_fields
    rescue StandardError => e
      Rails.logger.error("yrby-forms materialize failed for #{key}: #{e.class}: #{e.message}")
    end
  end

  def subscribed
    reject and return unless record.try(:collaborative_fields?)
    reject and return unless authorized?

    sync_subscribed(record.find_or_create_collaborative_fields_document.key)
  end

  def receive(data)
    return unless record

    sync_receive(data, record.find_or_create_collaborative_fields_document.key)
  end

  private

  # Demo only: anyone may edit. A real app checks the current user here.
  def authorized?
    true
  end

  # The token only verifies for the field-set document it was minted for
  # (the purpose is pinned, not read from params).
  def record
    @record ||= Y::Collaborative.locate(params[:sgid], Y::Forms::DOCUMENT_NAME)
  end
end
