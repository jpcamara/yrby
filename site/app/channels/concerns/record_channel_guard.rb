# Site limits for the record-backed channels the gems ship: yrby-rails'
# Y::DocumentChannel, lexxy-realtime's LexxyRealtime::DocumentChannel, and
# NoteChannel, which extends it. The guard keeps the gems' record lookup and
# storage hooks and adds the seats, frame limits, write budget, and awareness
# rules that RoomGuarded gives the room demos.
#
# config/initializers/record_channels.rb prepends it to Y::DocumentChannel, so
# every subclass gets it too. A client that subscribes to a parent class by
# name gets the same limits as one that subscribes to NoteChannel. Which
# records a channel opens is up to its authorize_document block.
module RecordChannelGuard
  # Checks access before taking a seat, so a refused client never holds one.
  # document.key computes the key without creating a row, so a join at the
  # room cap creates nothing.
  def subscribed
    return reject unless locate_record && authorized?(nil)
    return reject unless take_seat(document.key)

    super
  end

  # The gems' receive goes straight to sync_receive. This sends the frame
  # through RoomGuarded's checks first. It also looks up the record and checks
  # access again before every frame, as this site always has. The gems only
  # check at subscribe time.
  def receive(data)
    key = authorized_document_key
    return reject_document_subscription unless key && locate_record && authorized?(key)

    guarded_receive(data, key)
  end

  def unsubscribed
    release_seat(document.key) if seat && document
  end
end
