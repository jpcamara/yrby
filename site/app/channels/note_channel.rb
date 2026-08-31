# The lexxy-realtime channel: the shape `bin/rails generate
# lexxy_realtime:install` writes, with this site's throttle layers on top
# (RoomGuarded) and one loosening for public rooms (authorized?).
#
# The client does not name a document. It presents a signed GlobalID minted by
# the server for one record and one field — LexxyRealtime.sgid_purpose scopes
# the token to "lexxy_realtime/<field>", so a token minted elsewhere, for
# another purpose, or for another field fails to locate the record and the
# subscription is rejected. That flow is itself part of what this demo shows.
#
# Storage routes through the record's collaborative-document association, and
# after every recorded update the body column is refreshed from the full
# document via Y::Lexxy — the server-side render is why `note.body` is always
# a current HTML snapshot with no browser involved.
class NoteChannel < ApplicationCable::Channel
  include RoomGuarded

  on_load { |_key| record.find_or_create_collaborative_document(field).load_state }
  on_change do |key, update|
    record.find_or_create_collaborative_document(field).append(update)
    # The size cap is charged before the write (RoomGuarded#refuse_write?), so
    # there is no size bookkeeping here.
    #
    # Log render failures. The stored document renders again after the next
    # update. Raising would make the client resend an update the server
    # already has.
    begin
      record.refresh_collaborative_rich_text(field)
    rescue StandardError => e
      Rails.logger.error("lexxy-realtime render failed for #{key}: #{e.class}: #{e.message}")
    end
  end

  def subscribed
    return reject unless record&.collaborative_rich_text?(field) && authorized?
    return reject unless take_seat(prospective_key)

    sync_subscribed(record.find_or_create_collaborative_document(field).key)
  end

  def unsubscribed
    release_seat(prospective_key) if record
  end

  def receive(data)
    return unless record

    guarded_receive(data, record.find_or_create_collaborative_document(field).key)
  end

  private

  # In the generated template this is where the app's access check goes
  # (record.editable_by?(current_user)), and it defaults to false. These rooms
  # are public by design — the sgid already proves the token was minted by
  # this site for this record and field, and that is the whole access model
  # for an anonymous demo.
  def authorized?
    true
  end

  # Invalid, stale, or field-mismatched tokens return nil and are rejected by
  # subscribed.
  def record
    @record ||= GlobalID::Locator.locate_signed(params[:sgid], for: Note.sgid_purpose(field))
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def field
    params[:field].to_s
  end

  # The key the document WILL have, without creating it — Y::Document.for
  # derives "note/<id>/body" from the record binding. Seats and the room cap
  # are checked against this before find_or_create mints the row, so a
  # process at the cap refuses the join instead of creating the document
  # first and counting it after.
  def prospective_key
    "#{record.class.polymorphic_name.underscore}/#{record.id}/#{field}"
  end
end
