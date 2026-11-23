# frozen_string_literal: true

# Reads the lib0 encoding y-protocols frames use: variable-length unsigned
# integers, and byte strings prefixed with their length.
class WireReader
  def initialize(bytes)
    @bytes = bytes
    @at = 0
  end

  def uint
    value = 0
    shift = 0
    while true
      raise "Truncated protocol frame" if @at >= @bytes.bytesize
      byte = @bytes.getbyte(@at)
      @at += 1
      value |= (byte & 0x7f) << shift
      return value if byte < 0x80
      shift += 7
      raise "Protocol integer is too long" if shift > 49
    end
  end

  def bytes
    length = uint
    raise "Truncated protocol frame" if @at + length > @bytes.bytesize
    slice = @bytes.byteslice(@at, length)
    @at += length
    slice
  end

  def finish
    raise "Protocol frame has trailing bytes" if @at < @bytes.bytesize
  end
end

# The y-websocket protocol over ActionCable: the sync handshake, delivery of
# local updates until the server acknowledges them, and presence (Yjs
# awareness). host.js carries the cable messages; everything else is here.
class Sync
  RESEND_MS = 1000
  RENEW_MS = 10_000
  PRESENCE_TIMEOUT_MS = 30_000
  MESSAGE_SYNC = 0
  MESSAGE_AWARENESS = 1
  STEP1 = 0
  STEP2 = 1
  UPDATE = 2

  attr_reader :client_id, :error

  def initialize(document, channel, key, presence)
    @document = document
    @client_id = document.client_id
    @channel = channel
    @key = key
    @presence = presence
    @clock = 0
    @subscribed = false
    @connected = false
    @synced = false
    @opening = ""
    @has_opening = false
    @error = ""
    @sequences = []
    @unacknowledged = []
    @next_sequence = 1
    @resend_timer = 0
    @states = {}
    @clocks = {}
    @seen = {}
    @last_status = ""
  end

  def offline? = !@subscribed
  def synced? = @synced
  def pending = @sequences.size

  def connect
    return if @subscribed
    @subscribed = true
    @error = ""
    Host.host_cable_open(@channel, @key)
  end

  def disconnect
    return unless @subscribed
    if @connected
      @clock += 1
      transmit(MESSAGE_AWARENESS, -1, awareness("null"))
    end
    @subscribed = false
    lost
    Host.host_cable_close
  end

  def connected
    return unless @subscribed
    @connected = true
    @synced = false
    @error = ""
    transmit(MESSAGE_SYNC, STEP2, @document.diff(@opening)) if @has_opening
    @has_opening = false
    transmit(MESSAGE_SYNC, STEP1, @document.state_vector)
    say_presence
    resend
  end

  def disconnected
    lost if @subscribed
  end

  def rejected
    disconnect
    @error = "Document subscription was rejected"
  end

  def fail(message)
    @error = message
  end

  # One cable message: an acknowledgment, or a base64 protocol frame.
  def received(json)
    message = JSON.parse(json)
    return unless message.is_a?(Hash)
    if message.key?("ack")
      acknowledge(message["ack"])
      return
    end
    on_awareness = message.key?("awareness")
    encoded = on_awareness ? message["awareness"] : message["update"]
    return unless encoded.is_a?(String)
    frame = WireReader.new(encoded.unpack1("m0"))
    type = frame.uint
    if type == MESSAGE_AWARENESS
      payload = frame.bytes
      frame.finish
      receive_presence(payload)
    elsif type == MESSAGE_SYNC && !on_awareness
      step = frame.uint
      payload = frame.bytes
      frame.finish
      receive_sync(step, payload)
    elsif on_awareness
      raise "Non-awareness frame on the awareness channel"
    end
  end

  # Queues the document's new local updates and sends them.
  def flush
    @document.take_updates.each do |update|
      @sequences << @next_sequence
      @unacknowledged << update
      transmit(MESSAGE_SYNC, UPDATE, update, @next_sequence)
      @next_sequence += 1
    end
    schedule_resend
  end

  # The resend timer: send every unacknowledged update again.
  def resend
    @resend_timer = 0
    return unless @connected
    @sequences.each_with_index { |sequence, index| transmit(MESSAGE_SYNC, UPDATE, @unacknowledged[index], sequence) }
    schedule_resend
  end

  # The renewal timer: repeat our presence and forget peers that went quiet.
  def renew
    return unless @connected
    say_presence
    now = Host.host_now
    @states.keys.each do |id|
      @states.delete(id) if now - @seen[id] > PRESENCE_TIMEOUT_MS
    end
  end

  def presence=(state)
    @presence = state
    say_presence
  end

  # Everyone present, this tab first, as presence states with a clientID.
  def peers
    people = [peer(@client_id, @presence)]
    @states.each { |id, state| people << peer(id, state) }
    people
  end

  # True when the status changed since the last call.
  def status_changed?
    status = status_json
    return false if status == @last_status
    @last_status = status
    true
  end

  def status_json
    JSON.generate({
      "status" => !@subscribed ? "disconnected" : !@connected ? "connecting" : @synced ? "synced" : "connected",
      "connected" => @connected, "synced" => @synced, "offline" => !@subscribed,
      "pending" => @sequences.size, "clientID" => @client_id, "error" => @error, "peers" => peers,
    })
  end

  private

  def lost
    @connected = false
    @synced = false
    @has_opening = false
    Host.host_clear_timeout(@resend_timer) if @resend_timer > 0
    @resend_timer = 0
    @states.clear
  end

  def receive_sync(step, payload)
    if step == STEP1
      # The server can ask before the subscription is confirmed. Answer then.
      if @connected
        transmit(MESSAGE_SYNC, STEP2, @document.diff(payload))
      else
        @opening = payload
        @has_opening = true
      end
    elsif step == STEP2 || step == UPDATE
      @document.apply(payload)
      @synced = true if step == STEP2
    end
  end

  # Applies a whole awareness update, after checking every state in it.
  def receive_presence(payload)
    reader = WireReader.new(payload)
    ids = []
    clocks = []
    states = []
    reader.uint.times do
      ids << reader.uint
      clocks << reader.uint
      state = reader.bytes.force_encoding("UTF-8")
      parsed = JSON.parse(state)
      raise "Awareness states must be objects or null" unless parsed.nil? || parsed.is_a?(Hash)
      states << (parsed.nil? ? "" : state)
    end
    reader.finish
    now = Host.host_now
    ids.each_with_index do |id, index|
      clock = clocks[index]
      state = states[index]
      if id == @client_id
        # A stale copy of this tab claims a newer clock: reassert ours.
        if clock > @clock
          @clock = clock
          say_presence
        end
        next
      end
      known = @clocks.fetch(id, 0)
      next unless known < clock || (known == clock && state.empty? && @states.key?(id))
      if state.empty?
        @states.delete(id)
      else
        @states[id] = state
      end
      @clocks[id] = clock
      @seen[id] = now
    end
  end

  def acknowledge(id)
    return unless id.is_a?(Integer) && id >= 0
    return if !@sequences.empty? && id > @sequences.last
    while !@sequences.empty? && @sequences.first <= id
      @sequences.shift
      @unacknowledged.shift
    end
    schedule_resend
  end

  def schedule_resend
    if @sequences.empty? || !@connected
      Host.host_clear_timeout(@resend_timer) if @resend_timer > 0
      @resend_timer = 0
    elsif @resend_timer == 0
      @resend_timer = Host.host_timeout(RESEND_MS, Studio::RESEND_TIMER)
    end
  end

  def say_presence
    return unless @connected
    @clock += 1
    transmit(MESSAGE_AWARENESS, -1, awareness(@presence))
  end

  def awareness(state)
    entry = "".b
    entry << varuint(1) << varuint(@client_id) << varuint(@clock) << varbytes(state.b)
  end

  def transmit(type, step, payload, sequence = -1)
    return unless @connected
    frame = varuint(type)
    frame << varuint(step) if step >= 0
    frame << varbytes(payload)
    Host.host_cable_send([frame].pack("m0"), sequence)
  end

  def varuint(value)
    bytes = "".b
    while value > 0x7f
      bytes << ((value & 0x7f) | 0x80).chr
      value >>= 7
    end
    bytes << value.chr
  end

  # Appends to a local: Spinel drops a string that starts with a NUL byte
  # when << is called on a method's result directly.
  def varbytes(bytes)
    framed = varuint(bytes.bytesize)
    framed << bytes
    framed
  end

  def peer(id, state)
    person = JSON.parse(state)
    person["clientID"] = id
    person
  end
end
