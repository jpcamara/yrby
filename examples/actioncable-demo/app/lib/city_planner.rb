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
#   CityPlanner.new("demo:city", url: "ws://127.0.0.1:3000/cable").run
#
# `peer:` takes a Y::ActionCable::Client already made. The planner runs in
# whatever calls `run`: a thread, a script, or a task under Falcon.
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

  # The document: four maps keyed "x,y". People and the planner write the
  # first three; only the planner writes the last.
  TILES = "tiles"     # cell => tile name (City::TILES); absent is grass
  SIGNS = "signs"     # cell => a sign's text
  AUTHORS = "authors" # cell => "h:<name>" or AUTHOR, written with the tile
  CLAIMS = "claims"   # cell => "planner" while the planner means to build there

  def initialize(document_id, url: nil, peer: nil, stay: MAX_STAY, logger: nil)
    @document_id = document_id
    @logger = logger || Logger.new($stderr)
    @peer = peer || Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id },
                                                    root: nil, logger: @logger)
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

  # Build plan after plan until nothing is left to do. Returns :stop if
  # told to leave meanwhile.
  def work
    loop do
      note_writes
      map = City::Map.from(read(TILES), read(SIGNS))
      plan = City.plans(map, avoid).find { |candidate| !skipped?(candidate) }
      return show("idle") unless plan

      return :stop if build(plan) == :stop
    end
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

  # One tile, its author, and the claim it fills, in one update.
  def lay(cell, tile)
    key = City.key(*cell)
    update = doc.diff do |d|
      tile ? d.get_map(TILES)[key] = tile : d.get_map(TILES).delete(key)
      tile ? d.get_map(AUTHORS)[key] = AUTHOR : d.get_map(AUTHORS).delete(key)
      d.get_map(CLAIMS).delete(key)
    end
    @peer.send_update(update)
    tile ? @tiles[key] = tile : @tiles.delete(key)
    tile ? @authors[key] = AUTHOR : @authors.delete(key)
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
    changed = (tiles.keys | @tiles.keys).select { |key| tiles[key] != @tiles[key] && authors[key] != AUTHOR }
    changed.each { |key| @touched[City.parse_key(key)] = now if @authors[key] == AUTHOR }
    @tiles = tiles
    @authors = authors
    changed.filter_map { |key| City.parse_key(key)&.then { |cell| [cell, name_of(authors[key])] } }
  end

  def name_of(author) = author.to_s.delete_prefix("h:").then { |name| name.empty? ? "someone" : name }

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
