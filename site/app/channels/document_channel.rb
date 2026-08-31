# The collaborative document channel.
#
# The yrby half is the four lines under `include Y::ActionCable`: two hooks and
# two one-line actions. Everything else in this file exists because the rooms
# are public and anonymous, so `receive` is an open write surface (layers 3-6 of
# app/lib/limits.rb).
class DocumentChannel < ApplicationCable::Channel
  include Y::ActionCable

  on_load { |key| RoomStore.current.load(key) }
  on_change { |key, update| RoomStore.current.append(key, update) }

  # Largest frame this channel will decode. yrby drops anything bigger before
  # base64 decode and again after, so a client can't force a large allocation or
  # native parse.
  max_frame_bytes Limits::MAX_FRAME_BYTES

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

    @document_key = key
    return reject unless take_seat(key)

    @bucket = TokenBucket.new(capacity: Limits::FRAME_BURST, refill_per_second: Limits::FRAMES_PER_SECOND)
    sync_subscribed(key)
  end

  def unsubscribed
    return unless @seated

    RoomStore.current.leave(@document_key)
    @seated = false
  end

  def receive(data)
    unless @bucket.take
      close_if_flooding
      return
    end

    encoded = data.is_a?(Hash) ? data["update"] : nil
    return unless encoded.is_a?(String)
    return if encoded.bytesize > MAX_ENCODED_BYTES
    return if document_frame?(encoded) && refuse_write?

    sync_receive(data, @document_key)
  end

  private

  # A room already at MAX_DOCUMENT_BYTES goes read-only rather than growing.
  # The frame is dropped here, before it reaches `on_change`, so the store's own
  # DocumentFull guard stays a backstop and the update is never recorded
  # half-way. Awareness frames still flow, so presence keeps working in a frozen
  # room. The client keeps the dropped update queued and retries it, which is
  # what any dropped frame does in this protocol; the notice below is how the
  # page knows to stop and open a new room.
  def refuse_write?
    return false unless RoomStore.current.full?(@document_key)

    unless @notified_full
      @notified_full = true
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
  def close_if_flooding
    return if @bucket.drops < Limits::FRAME_DROPS_BEFORE_CLOSE

    logger.warn("DocumentChannel: closing flooding connection on #{@document_key}")
    connection.close(reason: "message rate limit", reconnect: false)
  end

  def take_seat(key)
    case RoomStore.current.join(key)
    when :ok
      @seated = true
    when :room_full
      logger.info("DocumentChannel: #{key} is at #{Limits::MAX_PEERS_PER_ROOM} peers")
      false
    when :too_many_rooms
      logger.warn("DocumentChannel: #{Limits::MAX_LIVE_ROOMS} live rooms; refusing #{key}")
      false
    end
  end
end
