# frozen_string_literal: true

require "json"
require "logger"
require "y/action_cable/client"

# A Ruby city planner. It joins a city document over the cable's websocket
# the way a browser does, reads the map once a burst of edits settles, and
# builds what the rules in City say is missing: roads to houses, bridges
# over water, a shop for a grown district, a park for a crowded block, and
# whatever a sign asks for. Everything it does goes through the document.
#
# It says what it will build before it builds it: the cells go into the
# `claims` map first, drawn on every page as markers; then its character
# walks there and lays one tile per tick, writing the tile and its author
# together; then the claims go. A person who writes near its claims, or
# stands where it means to build, stops it: it releases the claims, leaves
# that plan alone for a while, and moves on. Cells where a person overrode
# its work are left alone for a while too.
#
# With a model key set there is a mayor too (CityMayor): a sign the rules
# do not understand is read into one of the instructions they do, and the
# reading goes into the document beside the sign; streets and
# neighbourhoods get name signs as the town grows. Without a key, neither.
#
#   CityPlanner.new("demo:city", url: "ws://127.0.0.1:3000/cable").run
#
# `peer:` takes a Y::ActionCable::Client already made; `mayor:` a CityMayor,
# or nil for none. The planner runs in whatever calls `run`: a thread, a
# script, or a task under Falcon.
class CityPlanner # rubocop:disable Metrics/ClassLength -- the planner's whole life, in one place
  IDENTITY = { name: "Planner", color: "#e38628" }.freeze
  AUTHOR = "a:planner"
  QUIET = 1.5      # seconds without further edits before the map is read
  TICK = 0.15      # seconds between tiles while building
  STEP = 0.04      # seconds between cells while walking
  KEEP_ALIVE = 10  # seconds between presence refreshes; pages forget a peer after 30
  GONE = 45        # seconds without a presence renewal before a person counts as gone
  EMPTY_FOR = 120  # seconds with nobody else here before the planner leaves
  MAX_STAY = 2 * 60 * 60
  YIELD_REACH = 3  # a person's write this close to a claim stops the build
  MEMORY = 60      # seconds a cell is left alone after a person overrode the planner there
  COOLDOWN = 30    # seconds before a plan the planner yielded on is tried again
  PAUSE = 1.2      # seconds the "yielding" status stays up
  NAME_EVERY = 20  # seconds between one name and the next
  ASK_AGAIN = 60   # seconds before a question the mayor could not answer is asked again

  # The document: five maps keyed "x,y". People and the planner write the
  # first three; only the planner writes the last two.
  TILES = "tiles"       # cell => tile name (City::TILES); absent is grass
  SIGNS = "signs"       # cell => a sign's text
  AUTHORS = "authors"   # cell => "h:<name>" or AUTHOR, written with the tile
  CLAIMS = "claims"     # cell => "planner" while the planner means to build there
  READINGS = "readings" # cell => what the mayor read a sign as, or "none"

  def initialize(document_id, url: nil, peer: nil, stay: MAX_STAY, logger: nil, mayor: :default) # rubocop:disable Metrics/ParameterLists -- the peer, the stay, and the mayor
    @document_id = document_id
    @logger = logger || Logger.new($stderr)
    @peer = peer || Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id },
                                                    root: nil, logger: @logger)
    @mayor = mayor == :default ? CityMayor.default : mayor
    @asked = {}   # sign text => when the mayor was last asked about it
    @named_at = 0 # when the mayor last named something
    @stay = stay
    @presence = Y::Awareness.new
    @others = Y::Awareness.new
    @renewed = {} # client => [clock, when it last changed]
    @changes = Queue.new
    @tiles = {}   # the tiles as last read, to tell what others changed
    @authors = {} # the authors as last read
    @touched = {} # cell => when a person last overrode the planner there
    @skipped = {} # plan id => when it may be tried again
    @claimed = [] # the cells of the plan under way
    @pos = [City::WIDTH / 2, City::HEIGHT / 2]
    @status = "idle"
  end

  def run
    @peer.on_update { |_update, _doc, _changed| @changes << :changed }
    @peer.on_awareness { |frame| see(frame) }
    @peer.subscribe
    @logger.info("planner: joined #{@document_id}")
    note_writes
    show("idle")
    watch unless work == :stop
  ensure
    release
    @peer.send_awareness(@presence.clear_local_state)
    @peer.unsubscribe
  end

  # Leave, once the tile under way is laid.
  def stop = @changes << :stop

  private

  def doc = @peer.doc

  # Work after each burst of edits and say "still here" in the quiet. Leave
  # when told to, after a long stay, or once nobody else has been here for
  # a while.
  def watch
    started = now
    alone_since = nil
    while now - started < @stay
      case @changes.pop(timeout: KEEP_ALIVE)
      when :stop then return leave("told to")
      when nil then show(@status)
      else
        return leave("told to") if settle == :stop || work == :stop
      end
      alone_since = people_here.empty? ? alone_since || now : nil
      return leave("nobody else here") if alone_since && now - alone_since > EMPTY_FOR
    end
    leave("stayed long enough")
  end

  def leave(why) = @logger.info("planner: leaving #{@document_id}, #{why}")

  # Let a burst of edits settle. Returns :stop if told to leave meanwhile.
  def settle
    while (event = @changes.pop(timeout: QUIET))
      return :stop if event == :stop
    end
  end

  # Build plan after plan until nothing is left to do, then, with a mayor,
  # give one thing a name. Returns :stop if told to leave meanwhile.
  def work
    loop do
      note_writes
      map = City::Map.from(read(TILES), read(SIGNS), read(READINGS))
      map = read_signs(map)
      plan = City.plans(map, avoid).find { |candidate| !skipped?(candidate) }
      break unless plan

      return :stop if build(plan) == :stop
    end
    name_something
    show("idle")
  end

  # Ask the mayor about signs the rules do not understand, one question per
  # sign text, and put the reading in the document beside the sign. The
  # mayor's own name signs are not questions. A sign the mayor could not
  # read is asked about again later; the map comes back with the readings
  # in it.
  def read_signs(map)
    return map unless @mayor

    readings = unread_signs(map).filter_map do |x, y, text|
      @asked[text] = now
      show("reading a sign")
      meaning = @mayor.read(text)
      @logger.info("mayor: read #{text.inspect} as #{meaning || "nothing"}")
      [City.key(x, y), meaning ? meaning.to_s.upcase.tr("_", " ") : "none"]
    end
    return map if readings.empty?

    @peer.send_update(doc.diff { |d| readings.each { |key, meaning| d.get_map(READINGS)[key] = meaning } })
    City::Map.from(read(TILES), read(SIGNS), read(READINGS))
  end

  def unread_signs(map)
    map.signs_at.select do |x, y, text|
      !map.instruction_at(x, y) && !own?(@authors[City.key(x, y)]) && stale?(map, [x, y], text)
    end
  end

  # A sign needs reading when it has no reading yet, or the mayor answered
  # "none" a while ago and could be asked again.
  def stale?(map, cell, text)
    reading = map.readings[City.key(*cell)]
    return true unless reading
    return false unless reading == "none"

    now - @asked.fetch(text, 0) > ASK_AGAIN
  end

  # With a mayor, one name at a time: a sign beside a street or a
  # neighbourhood that has none, with the mayor's name on it.
  def name_something
    return unless @mayor && now - @named_at > NAME_EVERY

    map = City::Map.from(read(TILES), read(SIGNS), read(READINGS))
    kind, site = City.naming_sites(map, City.blocked(map, avoid)).first
    return unless site

    @named_at = now
    show("naming a #{kind}")
    name = @mayor.name(kind, taken: map.signs.values) or return
    @logger.info("mayor: named the #{kind} at #{site.join(",")} #{name.inspect}")
    lay(site, City::SIGN, author: CityMayor::AUTHOR, text: name)
  end

  # Claim the cells, walk to the first, lay them one per tick, and let the
  # claims go. Stops early when someone writes near the claims or stands
  # in the way; that plan then waits out a cooldown.
  def build(plan)
    @logger.info("planner: #{plan.goal}, #{plan.cells.size} cells from #{plan.cells.first.first(2).join(",")}")
    claim(plan)
    show(plan.goal)
    result = walk_to(plan.positions.first, plan)
    plan.cells.each do |x, y, tile|
      break if result

      result = check(plan, [x, y])
      next if result

      lay([x, y], tile)
      sleep TICK
    end
    release
    yielded(plan, result) if result.is_a?(String)
    result == :stop ? :stop : nil
  end

  def claim(plan)
    @claimed = plan.positions
    @peer.send_update(doc.diff { |d| plan.cell_keys.each { |key| d.get_map(CLAIMS)[key] = "planner" } })
  end

  def release
    @claimed = []
    keys = read(CLAIMS).keys
    return if keys.empty?

    @peer.send_update(doc.diff { |d| keys.each { |key| d.get_map(CLAIMS).delete(key) } })
  end

  # One tile, its author, and the claim it fills, in one update. A sign
  # carries its text too.
  def lay(cell, tile, author: AUTHOR, text: nil)
    key = City.key(*cell)
    update = doc.diff do |d|
      tile ? d.get_map(TILES)[key] = tile : d.get_map(TILES).delete(key)
      tile ? d.get_map(AUTHORS)[key] = author : d.get_map(AUTHORS).delete(key)
      d.get_map(SIGNS)[key] = text if text
      d.get_map(CLAIMS).delete(key)
    end
    @peer.send_update(update)
    tile ? @tiles[key] = tile : @tiles.delete(key)
    tile ? @authors[key] = author : @authors.delete(key)
    @pos = cell
    show(@status)
  end

  # Move the character to `target`, a cell per STEP, straight across
  # whatever is in the way. Returns what check returns, or nil on arrival.
  def walk_to(target, plan)
    until @pos == target
      result = check(plan, nil)
      return result if result

      @pos = [@pos[0] + (target[0] <=> @pos[0]), @pos[1] + (target[1] <=> @pos[1])]
      show(@status)
      sleep STEP
    end
    nil
  end

  # Between two steps: :stop when told to leave; the name of a person to
  # yield to when someone wrote within reach of the claims, or stands on
  # the cell about to be laid; nil to carry on.
  def check(plan, next_cell)
    while (event = @changes.pop(timeout: 0))
      return :stop if event == :stop
    end
    written = note_writes
    return nil unless plan

    near = written.find { |cell, _| City.near?([cell], @claimed, YIELD_REACH) }
    return near[1] if near

    standing = people.find { |person| person[:pos] == next_cell }
    standing && standing[:name]
  end

  def yielded(plan, name)
    @skipped[plan.id] = now + COOLDOWN
    @logger.info("planner: yielding to #{name} on #{plan.id}")
    show("yielding to #{name}")
    sleep PAUSE
  end

  def skipped?(plan) = @skipped.fetch(plan.id, 0) > now

  # What others changed since the last look, as [cell, name] pairs, the
  # planner's own writes left out. A cell where a person replaced or erased
  # the planner's tile is remembered, and avoided for a while.
  def note_writes
    tiles = read(TILES)
    authors = read(AUTHORS)
    changed = (tiles.keys | @tiles.keys).select { |key| tiles[key] != @tiles[key] && !own?(authors[key]) }
    changed.each { |key| @touched[City.parse_key(key)] = now if own?(@authors[key]) }
    @tiles = tiles
    @authors = authors
    changed.filter_map { |key| City.parse_key(key)&.then { |cell| [cell, name_of(authors[key])] } }
  end

  def name_of(author) = author.to_s.delete_prefix("h:").then { |name| name.empty? ? "someone" : name }
  def own?(author) = [AUTHOR, CityMayor::AUTHOR].include?(author)

  def avoid
    @touched.delete_if { |_, at| now - at > MEMORY }
    @touched.keys.compact
  end

  def read(name) = JSON.parse(doc.read_map(name) || "{}")

  # Presence in the shape the page gives every visitor, plus the status and
  # a mark that says which one is the planner.
  def show(status)
    @status = status
    state = { user: IDENTITY, planner: true, status: status, pos: { x: @pos[0], y: @pos[1] } }
    @peer.send_awareness(@presence.set_local_state(JSON.generate(state)))
  end

  # Everyone's presence, the planner's own echoed back among them, and when
  # each last renewed it. A page that closed without saying so stops
  # renewing, and after GONE seconds it no longer counts as here.
  def see(frame)
    @others.apply_update(frame)
    @others.clocks.each { |client, clock| @renewed[client] = [clock, now] unless @renewed.dig(client, 0) == clock }
  end

  def people_here
    @others.states.select do |client, state|
      client != @presence.client_id && state.is_a?(Hash) && now - @renewed.fetch(client, [0, now])[1] < GONE
    end.keys
  end

  # The people here, each with a name and the cell they stand on.
  def people
    @others.states.values_at(*people_here).filter_map do |state|
      pos = state["pos"]
      next unless state["user"].is_a?(Hash) && pos.is_a?(Hash)

      { name: state["user"]["name"].to_s, pos: [pos["x"], pos["y"]] }
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
