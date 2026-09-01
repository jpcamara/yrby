# The throttle layers every collaborative channel on this site shares — the
# rooms are public and anonymous, so `receive` is an open write surface
# whichever channel it reaches (layers 2-6 of config/limits.rb).
#
# Includers call `take_seat(key)` from `subscribed` (after their own
# authorization), `release_seat(key)` from `unsubscribed`, and route `receive`
# through `guarded_receive(data, key)`, which enforces, in order: the
# per-connection frame bucket (with the flooding close), the encoded frame size
# cap, the process-wide document-write budget, and the per-room document byte
# cap (document frames only; a full room goes read-only with a one-time notice,
# and awareness keeps flowing). Frames that pass go to yrby's `sync_receive`.
#
# The subscription itself is admitted by the connection guard first
# (subscription count, subscribe rate, one seat per room per connection), then a
# room seat is taken. Both the frame bucket and the subscription budget live on
# the CONNECTION, not the subscription, so a socket can't reset a burst or
# multiply a rate by re-subscribing.
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
    #   notified  the "room is full" notice has already been sent
    # The frame bucket and subscription budget are per-CONNECTION now
    # (ConnectionGuard), not here.
    state_attr_accessor :seat, :notified
  end

  # The demo does not use AnyCable whispers, and this is where it opts out.
  #
  # yrby's sync_subscribed enables a whisper stream for awareness under AnyCable
  # (`stream_from awareness, whisper: true`). A whisper relays client-to-client
  # through anycable-go and never reaches Rails, so on this public, anonymous,
  # mutually-untrusting surface a raw client could whisper a `{update: <document
  # frame>}` straight to its peers — past the token bucket, the size caps,
  # persistence, and every validation the receive path runs. Stripping the
  # whisper option means anycable-go never whisper-enables any of this channel's
  # streams, so it drops every whisper on them (a malicious one included).
  # Awareness instead rides the guarded `send` path: the client sends it, it
  # reaches guarded_receive, and the server relays it to the room like any other
  # frame (see guarded_receive). Whisper stays a first-class feature of the
  # published yrby-client and yrby-rails for real authenticated apps; only the
  # demo turns it off.
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

  # Document frames (an Update or a SyncStep2) are charged against the write
  # budget and the room byte cap before yrby sees them. Awareness and handshake
  # frames are not writes and pass straight through. Returns true when the frame
  # must be dropped here.
  def refuse_document_write?(encoded, key)
    bytes = safe_decode(encoded)
    return false unless bytes && document_frame?(bytes)

    update = Y.update_from_message(bytes)
    return false unless update

    refuse_write?(key, update.bytesize)
  end

  # A document write has to clear two aggregate gates before it is recorded: the
  # process-wide write budget (shed a flood before it reaches SQLite) and the
  # per-room byte cap (a room at MAX_DOCUMENT_BYTES goes read-only). Both drop
  # the frame here, before it reaches `on_change`, so the update is never
  # recorded half-way — raising from `on_change` would reject without acking,
  # and an unacked update is retransmitted forever. Awareness frames never reach
  # this path, so presence keeps working in a shed or frozen room. The client
  # keeps a dropped update queued and retries it; the notice below is how the
  # page knows a room is full and to open a new one.
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

  # Dropped frames are normal in bursts (a fast pointer drag emits awareness
  # at event rate). A client that keeps going well past the bucket is not a
  # person using a browser, so the socket goes. The drop count is the
  # connection's, across every subscription it holds.
  def close_if_flooding(key)
    return if ConnectionGuard.current.frame_drops(connection.connection_id) < Limits::FRAME_DROPS_BEFORE_CLOSE

    logger.warn("#{self.class.name}: closing flooding connection on #{key}")
    connection.close(reason: "message rate limit", reconnect: false)
  end
end
