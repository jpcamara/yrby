# The lexxy-realtime channel. It has the shape that `bin/rails generate
# lexxy_realtime:install` writes, plus this site's throttles (RoomGuarded) and
# a looser authorized? for public rooms.
#
# The client doesn't name a document. It sends a signed room token that the
# server made for one field (Note.room_token). The verifier is keyed by
# "lexxy_realtime/<field>", so a token made for another field, or an edited
# one, fails to verify and the subscription is rejected. The demo shows this
# field scoping on purpose. The token signs a room id instead of a record id so
# the page can render without creating a Note row. Otherwise a crawler would
# create rows on every GET with no limit (see DemosController#show).
#
# This channel creates the Note when a client subscribes, and only if the room
# budget allows it. It uses the same reservation logic as documents, so an
# anonymous GET never creates a row. Storage goes through the record's
# collaborative document association. After each recorded update, the server
# renders the full document with Y::Lexxy and saves it to the body column, so
# `note.body` is always current HTML without a browser involved.
class NoteChannel < ApplicationCable::Channel
  include RoomGuarded

  on_load { |_key| record.find_or_create_collaborative_document(field).load_state }
  on_change do |key, update|
    record.find_or_create_collaborative_document(field).append(update)
    # RoomGuarded#refuse_write? checks the size cap before the write, so this
    # doesn't track sizes.
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
    return reject unless (note = seat_note) && note.collaborative_rich_text?(field) && authorized?
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

  # sync_subscribed rejects the subscription unless this returns true.
  # `subscribed` also checks it first, so a refused client never takes a seat.
  # In the generated template, the app's access check goes here
  # (record.editable_by?(current_user)) and the default is false. These rooms
  # are public. A verified room token shows this site gave the client a token
  # for this field, and for an anonymous demo that's enough.
  def authorized?(_key = nil)
    true
  end

  # The room the token was made for, or nil if the token is missing, edited,
  # or for a different field. Every RPC command includes the token param, so
  # each new channel instance reads it again. The result is memoized for the
  # rest of the command.
  def room
    return @room if defined?(@room)

    @room = Note.verified_room(params[:token], field)
  end

  # The Note for this room. `subscribed` creates it within the room budget.
  # Every other command (receive, on_load, and on_change each run in their own
  # RPC instance) only looks it up, because the row exists by then.
  def record
    return @record if defined?(@record)

    @record = room && Note.find_by(room: room)
  end

  # Finds the room's Note, or creates it if the room budget allows. Fetching
  # pages creates nothing. Only a real subscribe gets here, and only when
  # there's budget for another room. The real reservation is still the `join`
  # in take_seat against the note's document key. This only stops a row from
  # being created past the cap.
  def seat_note
    return nil unless room

    @record = Note.find_by(room: room) || create_note_within_budget
  end

  def create_note_within_budget
    return nil unless Rooms.current.room_available?

    Note.create!(room: room)
  rescue ActiveRecord::RecordNotUnique
    Note.find_by(room: room) # another subscribe created it first
  end

  def field
    params[:field].to_s
  end

  # The key the document will have, without creating it. Y::Document.for
  # builds "note/<id>/body" from the record. Seats and the room cap are checked
  # against this key before find_or_create creates the document row, so a
  # process at the cap refuses the join before creating anything.
  def prospective_key
    "#{record.class.polymorphic_name.underscore}/#{record.id}/#{field}"
  end
end
