# Site limits for the record-backed channels the gems ship: yrby-rails'
# Y::DocumentChannel and lexxy-realtime's LexxyRealtime::DocumentChannel, and
# this site's RoomChannel and LexxyChannel, which extend them. The guard keeps
# the gems' record lookup and storage hooks and adds the seats, frame limits,
# write budget, and awareness rules from RoomGuarded.
#
# config/initializers/record_channels.rb prepends it to Y::DocumentChannel, so
# every subclass gets it too. A client that subscribes to a parent class by
# name gets the same limits as one that subscribes to a subclass. Which
# records a channel opens is up to its authorize_document block.
module RecordChannelGuard
  # Checks access before taking a seat, so a refused client never holds one.
  def subscribed
    return reject unless locate_record && authorized?(nil)
    return reject unless take_seat(record, params[:name].to_s)

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
    release_seat(record || locate_record, params[:name].to_s)
  end
end
