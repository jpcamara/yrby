# The collaborative document channel.
#
# The yrby half is the four lines under `include Y::ActionCable`: two hooks and
# two one-line actions. Everything else in this file exists because the rooms
# are public and anonymous, so `receive` is an open write surface (layers 3-6 of
# config/limits.rb).
#
# Sockets terminate in the anycable-go embedded in thrust, which calls this
# channel over HTTP RPC. That has one consequence worth knowing before reading
# further: a fresh channel instance is built for every command, so an instance
# variable set in `subscribed` is gone by the time `receive` runs. Everything
# that has to survive between commands is declared with `state_attr_accessor`,
# which travels as JSON in the RPC exchange. `params[:id]` is passed to
# `sync_receive` for the same reason.
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| RoomStore.current.load(key) }
  on_change { |key, update| RoomStore.current.append(key, update) }

  # Largest frame this channel will decode. yrby drops anything bigger before
  # base64 decode and again after, so a client can't force a large allocation or
  # native parse. anycable-go refuses larger frames before this, at the socket
  # (ANYCABLE_MAX_MESSAGE_SIZE); this is the same bound enforced in Ruby, for
  # the tests and for anyone running the app without the Go server.
  max_frame_bytes Limits::MAX_FRAME_BYTES

  # Per-subscription state, carried across RPC calls.
  #
  #   seat        this subscription holds a place in the room
  #   bucket      the token bucket, as [tokens, updated_at, drops]
  #   notified    the "room is full" notice has already been sent
  state_attr_accessor :seat, :bucket, :notified

  # Y.message_kind's code for a frame carrying document state (an Update or a
  # SyncStep2), as opposed to a handshake or an awareness frame.
  DOCUMENT_FRAME = 2

  # Same bound yrby applies to the encoded form before it decodes: base64 is
  # about 4/3 of the payload. Checked here too, because this channel decodes a
  # frame itself to classify it, and that decode has to be bounded as well.
  MAX_ENCODED_BYTES = ((Limits::MAX_FRAME_BYTES * 4) / 3) + 4

  def subscribed
    key = params[:id].to_s
    return reject unless Demos.valid_key?(key)
    return reject unless take_seat(key)

    self.bucket = TokenBucket.new(capacity: Limits::FRAME_BURST,
                                  refill_per_second: Limits::FRAMES_PER_SECOND).dump
    sync_subscribed(key)
  end

  def unsubscribed
    return unless seat

    RoomStore.current.leave(params[:id].to_s)
    self.seat = false
  end

  def receive(data)
    key = params[:id].to_s
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

  private

  # A room already at MAX_DOCUMENT_BYTES goes read-only rather than growing.
  # The frame is dropped here, before it reaches `on_change`, so the store's own
  # DocumentFull guard stays a backstop and the update is never recorded
  # half-way. Awareness frames still flow, so presence keeps working in a frozen
  # room. The client keeps the dropped update queued and retries it, which is
  # what any dropped frame does in this protocol; the notice below is how the
  # page knows to stop and open a new room.
  def refuse_write?(key)
    return false unless RoomStore.current.full?(key)

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

  # Dropped frames are normal in bursts (a fast pointer drag emits awareness at
  # event rate). A client that keeps going well past the bucket is not a person
  # using a browser, so the socket goes.
  def close_if_flooding(bucket, key)
    return if bucket.drops < Limits::FRAME_DROPS_BEFORE_CLOSE

    logger.warn("DocumentChannel: closing flooding connection on #{key}")
    connection.close(reason: "message rate limit", reconnect: false)
  end

  def take_seat(key)
    case RoomStore.current.join(key)
    when :ok
      self.seat = true
    when :room_full
      logger.info("DocumentChannel: #{key} is at #{Limits::MAX_PEERS_PER_ROOM} peers")
      false
    when :too_many_rooms
      logger.warn("DocumentChannel: #{Limits::MAX_LIVE_ROOMS} live rooms; refusing #{key}")
      false
    end
  end
end
