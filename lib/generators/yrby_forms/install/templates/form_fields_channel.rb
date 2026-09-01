# frozen_string_literal: true

# Syncs clients with a record's collaborative field set. After storing each
# update, the declared columns are refreshed from the full document.
class FormFieldsChannel < ApplicationCable::Channel
  include Y::ActionCable

  # Storage routes through the record's association, so an encrypted field
  # set reads and writes through Y::EncryptedDocument.
  on_load { |_key| record.find_or_create_collaborative_fields_document.load_state }
  on_change do |key, update|
    record.find_or_create_collaborative_fields_document.append(update)
    # Log materialization failures. The stored document materializes again
    # on the next update. Raising would make the client resend an update
    # the server already has.
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

  # Check whether the current user may edit this record, e.g.
  # record.editable_by?(current_user) with identified_by :current_user
  # on the connection. Nothing connects until this returns true.
  def authorized?
    false
  end

  # The token only verifies for the field-set document it was minted for
  # (the purpose is pinned, not read from params). Invalid, stale, or
  # tampered tokens return nil and are rejected by subscribed.
  def record
    @record ||= Y::Collaborative.locate(params[:sgid], Y::Forms::DOCUMENT_NAME)
  end
end
