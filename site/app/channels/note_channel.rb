# The Lexxy demo's channel. It's lexxy-realtime's own channel, which saves
# each update and then renders note.body from the whole document, with three
# changes for public, anonymous rooms. RecordChannelGuard adds this site's
# seats and throttles, the same as for every channel built on
# Y::DocumentChannel (see config/initializers/record_channels.rb).
#
# The page renders <yrby-document grant="<room token>" name="body"
# channel="NoteChannel">, so params[:grant] is a room token and params[:name]
# is the field.
class NoteChannel < LexxyRealtime::DocumentChannel
  # The rooms are public. A room token that verifies for this field shows this
  # site rendered the page, and for an anonymous demo that's enough. The block
  # replaces the example-only block that Y::DocumentChannel sets. The parent's
  # authorized? still rejects a field that isn't declared with
  # has_collaborative_rich_text.
  authorize_document { |_note, _name| true }

  # The page doesn't create the Note, so the first subscribe does, if the room
  # budget allows another room. The guard and the parent then find it through
  # locate_record. Without a valid token, or at the cap, nothing is created
  # and the parent rejects the subscription.
  def subscribed
    create_note_within_budget
    super
  end

  private

  # The grant is a room token, not a signed GlobalID. A page GET can't create
  # a Note row, because a crawler could then create rows without limit, so at
  # render time there's no record to sign. Note.room_token signs the room id
  # for one field instead. This finds the room's Note and never creates one,
  # because on_change and receive call it too. Returns nil for a missing,
  # edited, or wrong-field token, and before the first subscribe.
  def locate_record
    room = Note.verified_room(params[:grant], params[:name])
    @record = room && Note.find_by(room: room)
  end

  def create_note_within_budget
    room = Note.verified_room(params[:grant], params[:name])
    return if room.nil? || Note.exists?(room: room) || !Rooms.current.room_available?

    Note.create!(room: room)
  rescue ActiveRecord::RecordNotUnique
    nil # another subscribe created it first
  end
end
