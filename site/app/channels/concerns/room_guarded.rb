# Throttles shared by every collaborative channel on this site. The rooms are
# public and anonymous, so any client can send frames to `receive` on any of
# these channels (layers 2-6 of config/limits.rb).
#
# Channels that include this call `take_seat(key)` from `subscribed` after
# their own authorization, call `release_seat(key)` from `unsubscribed`, and
# send `receive` through `guarded_receive(data, key)`. That method checks, in
# order:
#
# 1. the per-connection frame bucket, closing the socket if it keeps flooding
# 2. the encoded frame size
# 3. the process-wide document write budget
# 4. the per-room document byte cap
#
# Steps 3 and 4 apply only to document frames. When a room hits its byte cap
# it goes read-only, the client gets one notice, and awareness keeps working.
# Frames that pass all four go to yrby's `sync_receive`.
#
# Before a seat is taken, the connection guard admits the subscription. It
# checks the subscription count, the subscribe rate, and that the connection
# has at most one seat per room. The frame bucket and the subscription budget
# are tracked per connection, so a socket can't reset a burst or multiply its
# rate by subscribing again.
#
# Sockets terminate in anycable-go and every command builds a new channel
# instance, so anything that has to last between commands is channel state.
module RoomGuarded
  extend ActiveSupport::Concern

  # The Y.message_kind code for a frame with document state (an Update or a
  # SyncStep2). Handshake and awareness frames have other codes.
  DOCUMENT_FRAME = 2

  # The same limit yrby applies to the encoded frame before decoding it. Base64
  # is about 4/3 the size of the payload. The channel decodes frames itself to
  # classify them, so it needs its own check before that decode.
  MAX_ENCODED_BYTES = ((Limits::MAX_FRAME_BYTES * 4) / 3) + 4

  included do
    include Y::ActionCable

    # The largest frame the channel will decode. yrby drops anything bigger,
    # before and after the base64 decode. anycable-go also rejects larger
    # frames at the socket (ANYCABLE_MAX_MESSAGE_SIZE). This setting applies the
    # same limit in Ruby for the tests and for anyone running the app without
    # the Go server.
    max_frame_bytes Limits::MAX_FRAME_BYTES

    # Per-subscription state, kept across RPC calls:
    #   seat      this subscription holds a place in the room
    #   notified  the "room is full" notice was already sent
    # ConnectionGuard tracks the frame bucket and subscription budget per
    # connection.
    state_attr_accessor :seat, :notified
  end

  # This demo turns off AnyCable whispers.
  #
  # Under AnyCable, yrby's sync_subscribed streams awareness with
  # `stream_from awareness, whisper: true`. A whisper goes from client to client
  # through anycable-go and never reaches Rails. On a public, anonymous site, a
  # raw client could whisper `{update: <document frame>}` to its peers and skip
  # the token bucket, the size caps, persistence, and every check in the
  # receive path. Removing the whisper option means anycable-go doesn't enable
  # whispers on any of this channel's streams, so it drops every whisper sent
  # to them.
  #
  # The client sends awareness through the normal `send` path, so it goes
  # through guarded_receive and the server relays it to the room like any other
  # frame. yrby-client and yrby-rails still support whispers for authenticated
  # apps. Only this demo turns them off.
  def stream_from(broadcasting, *args, **opts)
    opts.delete(:whisper)
    super
  end

  private

  def take_seat(key)
    case admit_subscription(key)
    when :ok
      seat_the_room(key)
    when :too_many
      logger.warn("#{self.class.name}: connection over its subscription cap; refusing #{key}")
      false
    when :duplicate
      logger.info("#{self.class.name}: connection already seated in #{key}")
      false
    when :rate_limited
      logger.warn("#{self.class.name}: connection subscribing too fast; refusing #{key}")
      false
    end
  end

  def seat_the_room(key)
    case Rooms.current.join(key)
    when :ok
      self.seat = true
      true
    when :room_full
      release_subscription(key)
      logger.info("#{self.class.name}: #{key} is at #{Limits::MAX_PEERS_PER_ROOM} peers")
      false
    when :too_many_rooms
      release_subscription(key)
      logger.warn("#{self.class.name}: #{Limits::MAX_LIVE_ROOMS} live rooms; refusing #{key}")
      false
    when :evicting
      release_subscription(key)
      logger.info("#{self.class.name}: #{key} is being evicted; refusing the join")
      false
    end
  end

  def release_seat(key)
    return unless seat

    Rooms.current.leave(key)
    release_subscription(key)
    self.seat = false
  end

  def admit_subscription(key)
    ConnectionGuard.current.admit_subscription(connection.connection_id, key)
  end

  def release_subscription(key)
    ConnectionGuard.current.release_subscription(connection.connection_id, key)
  end

  def guarded_receive(data, key)
    unless ConnectionGuard.current.take_frame(connection.connection_id)
      close_if_flooding(key)
      return
    end

    encoded = data.is_a?(Hash) ? data["update"] : nil
    return unless encoded.is_a?(String)
    return if encoded.bytesize > MAX_ENCODED_BYTES
    return if refuse_document_write?(encoded, key)

    sync_receive(data, key)
  end

  # Charges document frames (an Update or a SyncStep2) against the write budget
  # and the room byte cap before yrby sees them. Awareness and handshake frames
  # aren't writes, so they pass through. Returns true when the frame should be
  # dropped.
  def refuse_document_write?(encoded, key)
    bytes = safe_decode(encoded)
    return false unless bytes && document_frame?(bytes)

    update = Y.update_from_message(bytes)
    return false unless update

    refuse_write?(key, update.bytesize)
  end

  # A document write has to pass two checks before it's recorded. The
  # process-wide write budget stops a flood before it reaches SQLite. The
  # per-room byte cap makes a room read-only once it reaches MAX_DOCUMENT_BYTES.
  #
  # Both checks drop the frame here, before `on_change` runs, so an update is
  # never half recorded. Raising from `on_change` would reject the update
  # without acking it, and the client resends an unacked update forever.
  # Awareness frames never come through here, so presence keeps working in a
  # throttled or full room. The client keeps a dropped update queued and
  # retries it. The notice below tells the page that the room is full so it
  # can offer a new one.
  def refuse_write?(key, bytes)
    return true unless WriteBudget.current.admit

    return false if Rooms.current.reserve_write(key, bytes)

    unless notified
      self.notified = true
      transmit({ "notice" => "document_full", "limit" => Limits::MAX_DOCUMENT_BYTES })
    end
    true
  end

  def safe_decode(encoded)
    Base64.strict_decode64(encoded)
  rescue ArgumentError
    nil # not base64; sync_receive logs and drops it
  end

  def document_frame?(bytes)
    Y.message_kind(bytes) == DOCUMENT_FRAME
  end

  # Some dropped frames are normal during bursts. A fast pointer drag sends
  # awareness at event rate. A client that keeps sending well past the bucket
  # isn't a person in a browser, so the server closes the socket. The drop
  # count is per connection, across all its subscriptions.
  def close_if_flooding(key)
    return if ConnectionGuard.current.frame_drops(connection.connection_id) < Limits::FRAME_DROPS_BEFORE_CLOSE

    logger.warn("#{self.class.name}: closing flooding connection on #{key}")
    connection.close(reason: "message rate limit", reconnect: false)
  end
end
