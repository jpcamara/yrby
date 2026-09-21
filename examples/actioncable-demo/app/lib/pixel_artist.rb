# frozen_string_literal: true

require "json"
require "logger"
require "y/action_cable/client"
require_relative "pixel_canvas"
require_relative "pixel_planner"

# A real websocket peer. All Y.Doc access happens in this loop; the worker
# receives only an immutable raster and returns a proposed bounded patch.
class PixelArtist
  IDENTITY = { name: "Ruby", color: "#c85b50" }.freeze
  QUIET = 1.0
  INTERVAL = 5.0
  KEEP_ALIVE = 4.0
  GONE = 45
  EMPTY_FOR = 120
  MAX_STAY = 2 * 60 * 60
  TICK = 0.08
  STROKE = 8
  RUNNING = {}
  RUNNING_LOCK = Mutex.new

  def self.available? = PixelPlanner.available?
  def self.running?(document_id) = RUNNING_LOCK.synchronize { RUNNING.key?(document_id) }

  def initialize(document_id, url: nil, peer: nil, planner: nil, stop_version: "", stay: MAX_STAY,
                 quiet: QUIET, interval: INTERVAL, logger: nil)
    @document_id = document_id
    @stop_version = stop_version.to_s
    @logger = logger || Logger.new($stderr)
    @peer = peer || Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id },
                                                   root: nil, logger: @logger)
    @planner = planner || PixelPlanner.new
    @stay, @quiet, @interval = stay, quiet, interval
    @events = Queue.new
    @presence = Y::Awareness.new
    @others = Y::Awareness.new
    @renewed = {}
    @state = "Looking at the postcard"
    @phase = "idle"
    @turns = 0
    @last_started = -Float::INFINITY
  end

  def run
    acquired = RUNNING_LOCK.synchronize do
      next false if RUNNING.key?(@document_id)

      RUNNING[@document_id] = self
      true
    end
    return false unless acquired

    @peer.on_update { |*_args| @events << :changed }
    @peer.on_awareness { |frame| @events << [:awareness, frame] }
    @peer.subscribe
    @subscribed = true
    @turns = read_mural.fetch("turns", 0).to_i
    @previous_note = read_mural["note"]
    @joined = publish({ "enabled" => true, "model" => model_name, "mode" => "llm", "phase" => "idle",
                        "status" => @state, "changed" => 0 }, require_current_invite: true)
    return false unless @joined
    @observed = PixelCanvas.capture(doc)
    @pending_at = now # one initial contribution on joining
    show
    watch
    true
  ensure
    if acquired
      begin
        @worker&.kill
        @worker&.join(0.5)
        publish({ "enabled" => false, "phase" => "idle", "status" => "Ruby has left the canvas" }) if @joined
      ensure
        begin
          @peer.send_awareness(@presence.clear_local_state) if @joined
        ensure
          begin
            @peer.unsubscribe
          ensure
            RUNNING_LOCK.synchronize { RUNNING.delete(@document_id) if RUNNING[@document_id].equal?(self) }
          end
        end
      end
    end
  end

  # The main loop remains responsive while inference runs, so this also
  # cancels an in-flight network request rather than waiting for its timeout.
  def stop = @events << :stop

  private

  def doc = @peer.doc
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def model_name = @planner.respond_to?(:model) ? @planner.model : @planner.class.name
  def read_mural = JSON.parse(doc.read_map("mural") || "{}")

  def watch
    started = now
    heartbeat = now
    alone_since = nil
    while now - started < @stay
      events = [@events.pop(timeout: TICK)]
      63.times do
        events << @events.pop(true)
      rescue ThreadError
        break
      end
      mural = read_mural
      return if mural["enabled"] == false || mural["stop_version"].to_s != @stop_version

      changed = false
      events.each do |event|
        return if event == :stop

        case event
        when :changed then changed = true
        when Array
          case event.first
          when :awareness then see(event[1])
          when :result then result(*event.drop(1))
          end
        end
      end
      observe if changed
      paint if @painting && now >= @next_stroke
      start_plan if !@worker && !@painting && @pending_at && now >= @pending_at && now - @last_started >= @interval
      if now - heartbeat >= KEEP_ALIVE
        show
        heartbeat = now
        alone_since = people_here.empty? ? alone_since || now : nil
        return if alone_since && now - alone_since >= EMPTY_FOR
      end
    end
  end

  def observe
    current = PixelCanvas.capture(doc)
    return if current.signature == @observed.signature

    @observed = current
    @pending_at = now + @quiet
  end

  def start_plan
    snapshot = PixelCanvas.capture(doc)
    @observed = snapshot
    @pending_at = nil
    @last_started = now
    @state, @phase = "Thinking about your canvas", "thinking"
    publish({ "status" => @state, "phase" => @phase })
    show
    changes = snapshot.changes_since(@previous)
    previous_note = @previous_note
    @worker = Thread.new do
      Thread.current[:agent_purpose] = "pixel-artist:#{@document_id}"
      plan = @planner.call(snapshot, changes: changes, previous_note: previous_note)
      # Also validate injected planners: the mutation path never trusts a
      # provider or adapter to enforce its own output contract.
      plan = PixelCanvas.plan(note: plan.note, pixels: plan.pixels)
      @events << [:result, snapshot, plan, nil]
    rescue StandardError => e
      @events << [:result, snapshot, nil, e]
    end
  end

  def result(snapshot, plan, error)
    @worker = nil
    current = PixelCanvas.capture(doc)
    if current.signature != snapshot.signature
      @observed = current
      @pending_at ||= now + @quiet
      @state, @phase = "Your canvas changed; looking again", "idle"
      publish({ "status" => @state, "phase" => @phase })
      return
    end
    if error
      @logger.warn("pixel artist failed: #{error.class}")
      @state, @phase = error_message(error), "error"
      publish({ "status" => @state, "phase" => @phase, "note" => @state })
      show
      return
    end

    @next_stroke = now
    @painting = { snapshot: snapshot, plan: plan, pixels: current.writable(plan), changed: 0 }
    @state, @phase = "Adding a few pixels", "painting"
    publish({ "status" => @state, "phase" => @phase })
    show
  end

  def paint
    batch = @painting
    @next_stroke = now + TICK
    # Reject plans made obsolete by a new mark or direction, including edits
    # arriving after inference but before a later stroke of the same patch.
    current = PixelCanvas.capture(doc)
    if current.signature != batch[:snapshot].signature
      @painting = nil
      @observed = current
      @pending_at ||= now + @quiet
      @state, @phase = "Following your latest changes", "idle"
      publish({ "status" => @state, "phase" => @phase })
      return
    end
    pixels = batch[:pixels].shift(STROKE)
    @peer.send_update(doc.diff do |document|
      humans = document.get_map("pixels")
      artist = document.get_map("artist_pixels")
      pixels.each do |x, y, color|
        key = PixelCanvas.key(x, y)
        next if humans.key?(key) # protects even a mark arriving between reads

        artist[key] = color
        @cell = key
        batch[:changed] += 1
      end
    end)
    show unless pixels.empty?
    return unless batch[:pixels].empty?

    @turns += 1
    @previous = batch[:snapshot]
    @previous_note = batch[:plan].note
    @painting = nil
    @state, @phase = "Watching for your next idea", "idle"
    publish({ "status" => @state, "phase" => @phase, "note" => @previous_note,
              "turns" => @turns, "changed" => batch[:changed] })
    show
  end

  def publish(values, require_current_invite: false)
    accepted = false
    @peer.send_update(doc.diff do |document|
      map = document.get_map("mural")
      # A cancellation can arrive while subscribe is loading the room. Its
      # generation must still match inside the transaction that enables us.
      next if require_current_invite && map["stop_version"].to_s != @stop_version

      accepted = true
      values.each { |key, value| map[key] = value unless map.key?(key) && map[key] == value }
    end)
    accepted
  end

  def error_message(error)
    return error.message if error.is_a?(PixelPlanner::ModelError) || error.is_a?(PixelCanvas::InvalidPlan)

    "Ruby could not make a paint plan. Change the direction or re-invite Ruby to try again."
  end

  def show
    @peer.send_awareness(@presence.set_local_state(JSON.generate(user: IDENTITY, artist: true,
                                                                 status: @state, cell: @cell)))
  end

  def see(frame)
    @others.apply_update(frame)
    @others.clocks.each { |client, clock| @renewed[client] = [clock, now] unless @renewed.dig(client, 0) == clock }
  end

  def people_here
    @others.states.select do |client, state|
      client != @presence.client_id && state.is_a?(Hash) && now - @renewed.fetch(client, [0, now])[1] < GONE
    end.keys
  end
end
