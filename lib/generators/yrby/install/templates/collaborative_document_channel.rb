# frozen_string_literal: true

# Syncs clients with one record-bound collaborative document, declared on
# the model with has_collaborative_document or has_collaborative_rich_text.
# The form helper (collaborative_document_tag) mints the sgid and field
# params this channel authenticates with; after storing each update, the
# record's registered materialize step refreshes the derived columns.
class CollaborativeDocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  # Storage routes through the record's association, so an encrypted
  # attribute reads and writes through Y::EncryptedDocument.
  on_load { |_key| document.load_state }
  on_change do |key, update|
    document.append(update)
    # Log materialization failures. The stored document materializes again
    # on the next update. Raising would make the client resend an update
    # the server already has.
    begin
      record.refresh_collaborative_document(params[:field])
    rescue StandardError => e
      Rails.logger.error("yrby materialize failed for #{key}: #{e.class}: #{e.message}")
    end
  end

  def subscribed
    reject and return unless record.try(:collaborative_document?, params[:field])
    reject and return unless authorized?

    sync_subscribed(document.key)
  end

  def receive(data)
    return unless record

    sync_receive(data, document.key)
  end

  private

  # Check whether the current user may edit this record, e.g.
  # record.editable_by?(current_user) with identified_by :current_user
  # on the connection. Nothing connects until this returns true.
  def authorized?
    false
  end

  # The token only verifies for the attribute it was minted for: a sgid
  # for :body cannot open any other field. Invalid, stale, or tampered
  # tokens return nil and are rejected by subscribed.
  def record
    @record ||= Y::Collaborative.locate(params[:sgid], params[:field])
  end

  def document = record.find_or_create_collaborative_document(params[:field])
end
