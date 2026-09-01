# The lexxy-realtime channel: the shape `bin/rails generate
# lexxy_realtime:install` writes, with this site's throttle layers on top
# (RoomGuarded) and one loosening for public rooms (authorized?).
#
# The client does not name a document. It presents a signed, field-scoped ROOM
# token minted by the server (Note.room_token) — the verifier is keyed by
# "lexxy_realtime/<field>", so a token minted for another field or a tampered
# one fails to verify and the subscription is rejected. That field/purpose
# scoping is part of what this demo shows; signing a room id rather than a record
# id is what lets the page render without minting a Note row (a crawler would
# otherwise create rows on GET, uncapped — see DemosController#show).
#
# The Note itself is created HERE, on subscribe, and only within the room budget
# — the same reservation logic documents use — so creation is capacity-checked
# instead of happening on an anonymous GET. Storage then routes through the
# record's collaborative-document association, and after every recorded update
# the body column is refreshed from the full document via Y::Lexxy — the
# server-side render is why `note.body` is always a current HTML snapshot with no
# browser involved.
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

  # The gem's fail-closed seam: sync_subscribed rejects unless this returns
  # true (subscribed also asks first, so a refused client never takes a seat).
  # In the generated template this is where the app's access check goes
  # (record.editable_by?(current_user)), and it defaults to false. These rooms
  # are public by design — the verified room token already proves the client was
  # handed a token by this site for this field, and that is the whole access
  # model for an anonymous demo.
  def authorized?(_key = nil)
    true
  end

  # The room the token was minted for, or nil for a missing/tampered/field-
  # mismatched token. Memoized: every RPC command carries the token param, so
  # each fresh channel instance re-derives it.
  def room
    return @room if defined?(@room)

    @room = Note.verified_room(params[:token], field)
  end

  # The Note for this room, created on subscribe within the room budget. Every
  # non-subscribe command (receive/on_load/on_change runs in its own RPC
  # instance) only ever FINDS it — the row already exists by then, minted when
  # the room was first subscribed.
  def record
    return @record if defined?(@record)

    @record = room && Note.find_by(room: room)
  end

  # Find the room's Note, or mint it if the room budget allows. A crawler
  # fetching pages creates nothing; only a real subscribe reaches here, and only
  # when there is budget for another room, so the row is capacity-checked. The
  # authoritative reservation is still take_seat's `join` against the note's
  # document key; this only keeps a row from being minted past the cap.
  def seat_note
    return nil unless room

    @record = Note.find_by(room: room) || create_note_within_budget
  end

  def create_note_within_budget
    return nil unless Rooms.current.room_available?

    Note.create!(room: room)
  rescue ActiveRecord::RecordNotUnique
    Note.find_by(room: room) # a concurrent subscribe won the create
  end

  def field
    params[:field].to_s
  end

  # The key the document WILL have, without creating it — Y::Document.for
  # derives "note/<id>/body" from the record binding. Seats and the room cap
  # are checked against this before find_or_create mints the document row, so
  # a process at the cap refuses the join instead of creating the document
  # first and counting it after.
  def prospective_key
    "#{record.class.polymorphic_name.underscore}/#{record.id}/#{field}"
  end
end
