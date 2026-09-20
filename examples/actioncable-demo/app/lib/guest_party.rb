# frozen_string_literal: true

require_relative "guest"

# Eight guests on one cursors document, each a peer of its own. Under
# Falcon they run as child tasks of the invite's request; anywhere else,
# as threads. One party per room in this process.
#
#   GuestParty.new("demo:cursors", url: "ws://127.0.0.1:3000/cable").run
class GuestParty
  # Homes are spots along the board's edges, a chip's height clear of the
  # edge, clear of the seeded signs and of the slots around them, and out
  # of the open quadrant a crowd needs, so guests at the wall stand apart
  # and leave the floor free.
  PERSONAS = [
    Guest::Persona.new(name: "Snack Goblin", trait: "lives for free food", color: "#d97706", home: [24, 96],
                       personality: "lives for free food and will cross any room for a snack"),
    Guest::Persona.new(name: "Networker", trait: "here to schmooze", color: "#2563eb", home: [975, 170],
                       personality: "loves meeting people and any chance to schmooze"),
    Guest::Persona.new(name: "Introvert", trait: "seeks quiet corners", color: "#7c3aed", home: [975, 90],
                       personality: "avoids crowds and small talk; seeks quiet corners, " \
                                    "but will sit through a good talk"),
    Guest::Persona.new(name: "Rubyist", trait: "anything Ruby or Rails", color: "#dc2626", home: [24, 268],
                       personality: "gets excited about anything Ruby or Rails"),
    Guest::Persona.new(name: "Night Owl", trait: "loud, late, dancing", color: "#0f766e", home: [300, 500],
                       personality: "loves music, dancing, and anything loud and late"),
    Guest::Persona.new(name: "Pixel Nerd", trait: "lives for pixel art", color: "#db2777", home: [24, 460],
                       personality: "lives for pixel art and retro games"),
    Guest::Persona.new(name: "Coffee Snob", trait: "judges the beans", color: "#92400e", home: [24, 20],
                       personality: "only cares about good coffee and judges the beans"),
    Guest::Persona.new(name: "Lurker", trait: "lurks, unless it's irresistible", color: "#059669", home: [300, 20],
                       personality: "stays out of everything unless something is genuinely irresistible, " \
                                    "and a conference full of interesting people is")
  ].freeze

  # What every guest knows about places a sign may name: place => plain
  # facts, the same for all eight. A sign that is a place's name (trimmed,
  # any case) is offered with the facts; the briefing also goes with every
  # question as what_you_know. Nothing is written on the sign.
  BRIEFING = {
    "SF Ruby Conf" => "Nov 10-12 at SFJAZZ in San Francisco, three days of Ruby and Rails talks, " \
                      "keynote by Garry Tan, hosted by Evil Martians, hallway track, espresso bar, " \
                      "snacks between talks, evening party with music, a quiet lounge, " \
                      "8-bit theme with a pixel-art attendee world"
  }.freeze

  RUNNING = {} # rubocop:disable Style/MutableConstant -- the parties running in this process, by room
  RUNNING_LOCK = Mutex.new

  def self.available? = GuestMind.available?
  def self.running?(document_id) = RUNNING_LOCK.synchronize { RUNNING.key?(document_id) }

  # `peers:` makes a peer per persona, for tests; `guest:` are options
  # every Guest gets, such as `quiet:` and `stay:`.
  def initialize(document_id, url: nil, peers: nil, mind: nil, logger: nil, guest: {}) # rubocop:disable Metrics/ParameterLists -- the cable, the seams, and the guests' options
    @document_id = document_id
    @url = url
    @peers = peers
    @mind = mind
    @logger = logger || (defined?(Rails) && Rails.logger) || Logger.new($stderr)
    @options = guest
    @guests = []
    @threads = []
  end

  # False when a party is already in this room.
  def run
    acquired = RUNNING_LOCK.synchronize do
      next false if RUNNING.key?(@document_id)

      RUNNING[@document_id] = self
      true
    end
    return false unless acquired

    mind = @mind || GuestMind.new(logger: @logger).tap(&:warm) # one mind, stateless between calls
    @guests = PERSONAS.map do |persona|
      Guest.new(@document_id, persona, url: @url, peer: @peers&.call(persona), mind: mind, logger: @logger,
                                       briefing: BRIEFING, **@options)
    end
    host
    true
  ensure
    RUNNING_LOCK.synchronize { RUNNING.delete(@document_id) if RUNNING[@document_id].equal?(self) } if acquired
  end

  # Every guest at once: as child tasks on a reactor, as threads otherwise.
  def host
    if Async::Task.current?
      @guests.map { |guest| Async::Task.current.async { guest.run } }.each(&:wait)
    else
      @threads = @guests.map { |guest| Thread.new { guest.run } }
      @threads.each(&:join)
    end
  end

  # Send every guest home and wait for them.
  def stop(timeout: 10)
    @guests.each(&:stop)
    @threads.each { |thread| thread.join(timeout) }
  end
end
