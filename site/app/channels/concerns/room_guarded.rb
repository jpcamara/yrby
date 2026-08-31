# The throttle layers every collaborative channel on this site shares — the
# rooms are public and anonymous, so `receive` is an open write surface
# whichever channel it reaches (layers 3-6 of config/limits.rb).
#
# Includers call `take_seat(key)` from `subscribed` (after their own
# authorization), `release_seat(key)` from `unsubscribed`, and route `receive`
# through `guarded_receive(data, key)`, which enforces, in order: the token
# bucket (with the flooding close), the encoded frame size cap, and the
# document byte cap (document frames only; a full room goes read-only with a
# one-time notice, and awareness keeps flowing). Frames that pass go to yrby's
# `sync_receive`.
#
# Everything that must survive between commands is channel state, because
# sockets terminate in anycable-go and every command builds a fresh channel
# instance.
module RoomGuarded
  extend ActiveSupport::Concern

  # Y.message_kind's code for a frame carrying document state (an Update or a
  # SyncStep2), as opposed to a handshake or an awareness frame.
  DOCUMENT_FRAME = 2

  # Same bound yrby applies to the encoded form before it decodes: base64 is
  # about 4/3 of the payload. Checked here too, because the channel decodes a
  # frame itself to classify it, and that decode has to be bounded as well.
  MAX_ENCODED_BYTES = ((Limits::MAX_FRAME_BYTES * 4) / 3) + 4

  included do
    include Y::ActionCable

    # Largest frame the channel will decode. yrby drops anything bigger before
    # base64 decode and again after. anycable-go refuses larger frames at the
    # socket (ANYCABLE_MAX_MESSAGE_SIZE); this is the same bound in Ruby, for
    # the tests and for anyone running the app without the Go server.
    max_frame_bytes Limits::MAX_FRAME_BYTES

    # Per-subscription state, carried across RPC calls:
    #   seat      this subscription holds a place in the room
    #   bucket    the token bucket, as [tokens, updated_at, drops]
    #   notified  the "room is full" notice has already been sent
    state_attr_accessor :seat, :bucket, :notified
  end

  private

  def take_seat(key)
    case Rooms.current.join(key)
    when :ok
      self.bucket = TokenBucket.new(capacity: Limits::FRAME_BURST,
                                    refill_per_second: Limits::FRAMES_PER_SECOND).dump
      self.seat = true
    when :room_full
      logger.info("#{self.class.name}: #{key} is at #{Limits::MAX_PEERS_PER_ROOM} peers")
      false
    when :too_many_rooms
      logger.warn("#{self.class.name}: #{Limits::MAX_LIVE_ROOMS} live rooms; refusing #{key}")
      false
    end
  end

  def release_seat(key)
    return unless seat

    Rooms.current.leave(key)
    self.seat = false
  end

  def guarded_receive(data, key)
    bucket = TokenBucket.load(self.bucket, capacity: Limits::FRAME_BURST,
                                           refill_per_second: Limits::FRAMES_PER_SECOND)
    allowed = bucket.take
    self.bucket = bucket.dump

    unless allowed
      close_if_flooding(bucket, key)
      return
    end

    encoded = data.is_a?(Hash) ? data["update"] : nil
    return unless encoded.is_a?(String)
    return if encoded.bytesize > MAX_ENCODED_BYTES
    return if document_frame?(encoded) && refuse_write?(key)

    sync_receive(data, key)
  end

  # A room already at MAX_DOCUMENT_BYTES goes read-only rather than growing.
  # The frame is dropped here, before it reaches `on_change`, so the update is
  # never recorded half-way — raising from `on_change` would reject without
  # acking, and an unacked update is retransmitted forever. Awareness frames
  # still flow, so presence keeps working in a frozen room. The client keeps
  # the dropped update queued and retries it; the notice below is how the page
  # knows to stop and open a new room.
  def refuse_write?(key)
    return false unless Rooms.current.document_full?(key)

    unless notified
      self.notified = true
      transmit({ "notice" => "document_full", "limit" => Limits::MAX_DOCUMENT_BYTES })
    end
    true
  end

  def document_frame?(encoded)
    Y.message_kind(Base64.strict_decode64(encoded)) == DOCUMENT_FRAME
  rescue ArgumentError
    false # not base64; sync_receive logs and drops it
  end

  # Dropped frames are normal in bursts (a fast pointer drag emits awareness
  # at event rate). A client that keeps going well past the bucket is not a
  # person using a browser, so the socket goes.
  def close_if_flooding(bucket, key)
    return if bucket.drops < Limits::FRAME_DROPS_BEFORE_CLOSE

    logger.warn("#{self.class.name}: closing flooding connection on #{key}")
    connection.close(reason: "message rate limit", reconnect: false)
  end
end
