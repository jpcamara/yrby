# frozen_string_literal: true

require "json"
require "logger"
require "y/action_cable/client"
require_relative "guest_mind"

# One party guest: a Ruby process's peer on the cursors document. It joins
# over the cable's websocket the way a browser does, publishes its presence
# (a name, a color, a trait, and the sign it stands at) the way a browser
# publishes a cursor, and follows the signs. Whenever a sign's text
# changes, or a sign comes or goes, the guest asks its mind which sign to
# walk to and updates `at`. Moving a sign changes nothing it decides on:
# the pages glide the guest along with the sign.
#
# The mind runs off this loop: as a child task when the guest runs on an
# Async reactor (Falcon, a script under Sync), as a thread otherwise
# (Puma). Either way the loop keeps the presence fresh meanwhile, and the
# answer comes back through the same queue. A decision made against signs
# that changed while it was out is dropped and asked again. The guest
# leaves when told to, when the party is over (`party.enabled == false`),
# after `stay`, or once no person has been here for a while.
class Guest # rubocop:disable Metrics/ClassLength -- one peer's whole life in one place
  Persona = Data.define(:name, :trait, :personality, :color, :home)

  QUIET = 0.35        # seconds after the last sign change before asking
  MIN_INTERVAL = 1.0  # seconds between two asks
  KEEP_ALIVE = 4.0    # seconds between presence refreshes; pages forget a peer after 30
  GONE = 45           # seconds without a renewal before a person counts as gone
  EMPTY_FOR = 120     # seconds with no person here before the guest leaves
  MAX_STAY = 2 * 60 * 60
  TICK = 0.05

  SIGNS = "signs" # id => { x, y, text }
  PARTY = "party" # enabled => true | false

  def initialize(document_id, persona, url: nil, peer: nil, mind: nil, quiet: QUIET, # rubocop:disable Metrics/ParameterLists -- the peer, the mind, and the timings
                 min_interval: MIN_INTERVAL, stay: MAX_STAY, logger: nil)
    @document_id = document_id
    @persona = persona
    @logger = logger || Logger.new($stderr)
    @peer = peer || Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id },
                                                    root: nil, logger: @logger)
    @mind = mind || GuestMind.new(logger: @logger)
    @quiet = quiet
    @min_interval = min_interval
    @stay = stay
    @events = Queue.new
    @presence = Y::Awareness.new
    @others = Y::Awareness.new
    @renewed = {}
    @status = "arriving"
    @last_started = -Float::INFINITY
  end

  def run
    @peer.on_update { |*_args| @events << :changed }
    @peer.on_awareness { |frame| @events << [:awareness, frame] }
    @peer.subscribe
    @joined = true
    log("joined")
    return leave("party over") if party_over?

    @observed = signature
    @pending_at = now # one decision on arriving
    show("arriving")
    watch
  ensure
    cancel
    begin
      @peer.send_awareness(@presence.clear_local_state) if @joined
    ensure
      @peer.unsubscribe
    end
  end

  # Leave. The loop stays responsive while the mind is out, so this also
  # cancels an in-flight request.
  def stop = @events << :stop

  private

  def doc = @peer.doc
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def read(name) = JSON.parse(doc.read_map(name) || "{}")
  def party_over? = read(PARTY)["enabled"] == false

  # The signs with text, in a fixed order: [[id, text], ...]. A blank sign
  # is not a sign yet.
  def signs
    read(SIGNS).filter_map do |id, sign|
      text = sign.is_a?(Hash) ? sign["text"].to_s.strip : ""
      [id, text] unless text.empty?
    end.sort_by(&:first)
  end

  # What a decision depends on: the signs and their texts, not where they are.
  def signature = signs

  def watch
    started = now
    @heartbeat = now
    while now - started < @stay
      events = drain
      return leave("told to") if events.include?(:stop)
      return leave("party over") if events.include?(:changed) && party_over?

      events.each { |event| handle(event) }
      decide if due?
      why = keep_alive
      return leave(why) if why
    end
    leave("stayed long enough")
  end

  def handle(event)
    case event
    when :changed then observe
    when Array
      case event.first
      when :awareness then see(event[1])
      when :result then result(*event.drop(1))
      end
    end
  end

  def due? = @pending_at && !@worker && now >= @pending_at && now - @last_started >= @min_interval

  # Refresh the presence now and then, and notice an empty room.
  def keep_alive
    return if now - @heartbeat < KEEP_ALIVE

    show
    @heartbeat = now
    @alone_since = people_here.empty? ? @alone_since || now : nil
    "nobody here" if @alone_since && now - @alone_since >= EMPTY_FOR
  end

  def drain
    events = [@events.pop(timeout: TICK)]
    63.times do
      events << @events.pop(true)
    rescue ThreadError
      break
    end
    events.compact
  end

  def observe
    current = signature
    return if current == @observed

    @observed = current
    @pending_at = now + @quiet
  end

  # Ask the mind, off this loop. The signature the answer was made for
  # travels with it, so a stale answer can be told from a fresh one.
  def decide
    @pending_at = nil
    @last_started = now
    current = signs
    @observed = current
    @at = nil unless current.any? { |id, _text| id == @at }
    if current.empty?
      @decision = nil
      return show("settled")
    end

    show("deciding")
    persona = @persona
    at = @at
    ask = lambda do
      decision = @mind.call(persona: persona, signs: current, current: at)
      @events << [:result, current, decision, nil]
    rescue StandardError => e
      @events << [:result, current, nil, e]
    end
    @worker = Async::Task.current? ? Async::Task.current.async { ask.call } : Thread.new(&ask)
  end

  # Whatever the mind is doing, it is done. An answer still in flight would
  # only be dropped, so its request is cut short rather than waited for.
  def cancel
    return unless @worker

    if @worker.is_a?(Thread)
      @worker.kill
      @worker.join(0.5)
    else
      @worker.stop unless @worker.finished?
    end
    @worker = nil
  end

  def result(asked, decision, error)
    @worker = nil
    if asked != signature
      @pending_at ||= now + @quiet # the signs changed meanwhile: ask again
    elsif error
      # A mind's error names the failing class; anything else is logged by class.
      log("decision", status: "error", error_class: error.is_a?(GuestMind::Error) ? error.message : error.class.name)
      @decision = nil
      show("confused")
    else
      settle(decision, asked.size)
    end
  end

  def settle(decision, offered)
    @at = decision.choice unless decision.choice == GuestMind::STAY
    @decision = { "choice" => decision.choice, "sign" => decision.choice,
                  "p" => decision.probabilities[decision.choice], "ms" => decision.ms,
                  "model" => decision.model, "at" => (Time.now.to_f * 1000).round }
    log("decision", status: "ok", choice: decision.choice, p: @decision["p"], confidence: decision.confidence,
                    ms: decision.ms, model: decision.model, signs: offered)
    show("settled")
  end

  # Presence in the shape the page gives every person, plus what a guest is.
  def show(status = @status)
    @status = status
    state = { user: { name: @persona.name, color: @persona.color }, guest: true, trait: @persona.trait,
              home: @persona.home, at: @at, status: @status, decision: @decision }
    @peer.send_awareness(@presence.set_local_state(JSON.generate(state)))
  end

  def see(frame)
    @others.apply_update(frame)
    @others.clocks.each { |client, clock| @renewed[client] = [clock, now] unless @renewed.dig(client, 0) == clock }
  end

  # The people, not the guests: a room with only guests in it is empty.
  def people_here
    @others.states.select do |client, state|
      client != @presence.client_id && state.is_a?(Hash) && !state["guest"] &&
        now - @renewed.fetch(client, [0, now])[1] < GONE
    end.keys
  end

  def leave(why) = log("left", why: why)

  # JSON lines: names, ids, timings, and outcomes. Never a sign's text.
  def log(event, **fields)
    @logger.info(JSON.generate(event: "guest_#{event}", guest: @persona.name, room: @document_id, **fields))
  end
end
