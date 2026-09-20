# frozen_string_literal: true

require "json"
require "logger"
require "y/action_cable/client"

# The life of the town: a Ruby peer that joins a city document the way the
# planner does and walks its townsfolk about. Nothing it does goes into the
# document. Everything that moves lives in its one awareness state, sent
# twice a second: a dozen or two pedestrians on the roads people and the
# planner built (or the grass, before there are roads), a few cars, a cable
# car when there is track, gulls and boats over the bay, which chimneys are
# smoking, and the time of day. Pages draw all of it and forget it when the
# peer leaves; the document never sees a footstep.
#
#   CityLife.new("demo:city", url: "ws://127.0.0.1:3000/cable").run
#
# `peer:` takes a Y::ActionCable::Client already made. The peer runs in
# whatever calls `run`: a thread, a script, or a task under Falcon. The
# rules of who walks where are in Town, which knows nothing of the cable.
class CityLife
  IDENTITY = { name: "Townsfolk", color: "#7c9c4a" }.freeze
  TICK = 0.5       # seconds between steps, and between presence frames
  GONE = 45        # seconds without a presence renewal before a person counts as gone
  EMPTY_FOR = 120  # seconds with nobody else here before the peer leaves
  MAX_STAY = 2 * 60 * 60

  TILES = "tiles"
  SIGNS = "signs"
  READINGS = "readings"
  META = "meta" # the terrain's seed, under "seed"

  def initialize(document_id, url: nil, peer: nil, stay: MAX_STAY, logger: nil, rng: Random.new) # rubocop:disable Metrics/ParameterLists -- the peer, the stay, and the dice
    @document_id = document_id
    @logger = logger || Logger.new($stderr)
    @peer = peer || Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id },
                                                    root: nil, logger: @logger)
    @stay = stay
    @rng = rng
    @presence = Y::Awareness.new
    @others = Y::Awareness.new
    @renewed = {}
    @events = Queue.new
    @changed = true
  end

  def run
    @peer.on_update { |_update, _doc, _changed| @changed = true }
    @peer.on_awareness { |frame| see(frame) }
    @peer.subscribe
    @logger.info("life: joined #{@document_id}")
    @town = Town.new(read_map, rng: @rng, now: now)
    live
  ensure
    @peer.send_awareness(@presence.clear_local_state)
    @peer.unsubscribe
  end

  # Leave, after the step under way.
  def stop = @events << :stop

  private

  def doc = @peer.doc

  # A step every TICK: read the map again if it changed, move everyone,
  # say so. Leave when told to, after a long stay, or once nobody else has
  # been here for a while.
  def live
    started = now
    alone_since = nil
    while now - started < @stay
      return leave("told to") if @events.pop(timeout: TICK) == :stop

      if @changed
        @changed = false
        @town.map = read_map
      end
      @town.step(now)
      publish
      alone_since = people_here.empty? ? alone_since || now : nil
      return leave("nobody else here") if alone_since && now - alone_since > EMPTY_FOR
    end
    leave("stayed long enough")
  end

  def leave(why) = @logger.info("life: leaving #{@document_id}, #{why}")

  def read(name) = JSON.parse(doc.read_map(name) || "{}")

  def read_map
    City::Map.from(read(TILES), read(SIGNS), read(READINGS), seed: read(META)["seed"])
  end

  def publish
    state = { user: IDENTITY, life: true, status: "#{@town.walkers.size} out and about" }.merge(@town.state)
    @peer.send_awareness(@presence.set_local_state(JSON.generate(state)))
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

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The town's comings and goings, one step at a time. `step` moves
  # everyone one tick on; `state` is what goes out in the presence frame.
  class Town # rubocop:disable Metrics/ClassLength -- the townsfolk, the traffic, the birds, and the clock
    PEOPLE_MIN = 12
    PEOPLE_MAX = 20
    HOUSES_PER_PERSON = 2  # one more walker for every two houses, up to the most
    PAUSE = (4..10)        # ticks spent at a shop or a park
    SAY_EVERY = 4.0        # seconds between one bubble and the next, town-wide
    SAY_AGAIN = 20.0       # seconds before the same walker speaks again
    SAY_FOR = 4.0          # seconds a bubble stays up
    CARS_MAX = 4
    ROAD_PER_CAR = 15      # road cells per car
    TRAMS_MAX = 2
    TRACK_PER_TRAM = 12    # cable cells per cable car
    GULLS = 3
    BOATS = 2
    DAY = 360.0            # seconds in a day
    SMOKE_FLIP = 0.01      # chance per tick a chimney lights or goes out
    REACH = 30             # cells a walker will set out for at a time
    SEARCH = 800           # cells a route search will visit

    NAMES = %w[Ada Grace Linus Yukihiro Barbara Dennis Radia Alan Margaret Ken Guido Brendan Hedy Edsger Frances
               Bjarne Anita Niklaus Mary Tim Rasmus Larry Jean Rich Sophie Matz Audrey Charles Katherine Rob].freeze
    GENERIC = ["hello!", "lovely day", "nice town", "who built this?", "fog's rolling in", "hi neighbour",
               "what a place", "I love it here", "mind the cable car", "anyone seen the planner?"].freeze

    Walker = Struct.new(:name, :sprite, :x, :y, :face, :path, :wait, :say, :say_until, :said_at, keyword_init: true)
    Car = Struct.new(:x, :y, :dx, :dy, :kind, keyword_init: true)
    Gull = Struct.new(:x, :y, :dx, :dy, keyword_init: true)
    Boat = Struct.new(:x, :y, :dy, keyword_init: true)

    attr_reader :walkers, :cars, :gulls, :boats, :clock, :map

    def initialize(map, rng: Random.new, now: 0.0, start: 0.3)
      @rng = rng
      @walkers = []
      @cars = []
      @gulls = []
      @boats = []
      @lit = {}
      @last_say = -SAY_EVERY
      @t0 = now
      @start = start
      @clock = start
      @tick = 0
      self.map = map
    end

    # A new map: the roads and the water are looked up once per change.
    def map=(map)
      @map = map
      @roads = Set.new(map.roads)
      @track = Set.new(map.cells_with([City::CABLE]))
      @water = (0...City::HEIGHT).flat_map { |y| (0...City::WIDTH).filter_map { |x| [x, y] if map.water?(x, y) } }
      @stops = Set.new((map.shops + map.parks).flat_map { |x, y| map.beside(x, y) }.select { |c| @roads.include?(c) })
    end

    def step(now)
      @tick += 1
      @clock = (@start + ((now - @t0) / DAY)) % 1.0
      populate
      @walkers.each { |w| step_walker(w, now) }
      @cars.each { |c| 2.times { drive(c) } }
      @gulls.each { |g| fly(g) }
      @boats.each { |b| sail(b) } if @tick.even?
      smoulder
      speak(now)
    end

    # Everyone and everything, as small arrays: the frame goes out twice a
    # second to every page.
    def state
      {
        clock: @clock.round(4),
        peds: @walkers.map { |w| [w.name, w.sprite, w.x, w.y, w.face, w.say] },
        cars: @cars.map { |c| [c.x, c.y, c.dx, c.dy, c.kind] },
        gulls: @gulls.map { |g| [g.x, g.y, g.dx] },
        boats: @boats.map { |b| [b.x, b.y, b.dy] },
        smoke: @lit.select { |_, lit| lit }.keys.first(60)
      }
    end

    def smoke = @lit.select { |_, lit| lit }.keys

    private

    # --- who is about ------------------------------------------------------

    # More walkers as the town grows; cars once there is road for them; a
    # cable car once there is track; gulls and boats once there is water.
    def populate
      wanted = [PEOPLE_MIN + (@map.houses.size / HOUSES_PER_PERSON), PEOPLE_MAX].min
      @walkers << spawn_walker while @walkers.size < wanted
      populate_traffic
      populate_bay
    end

    # Cars whose road is gone are gone; the rest are topped up to the count
    # the road allows.
    def populate_traffic
      @cars.select! { |c| (c.kind == "tram" ? @track : @roads).include?([c.x, c.y]) }
      trams, cars = @cars.partition { |c| c.kind == "tram" }
      wanted_cars = [@roads.size / ROAD_PER_CAR, CARS_MAX].min
      wanted_trams = [@track.size / TRACK_PER_TRAM, TRAMS_MAX].min
      cars << spawn_car while cars.size < wanted_cars
      trams << spawn_car(tram: true) while trams.size < wanted_trams
      @cars = cars.first(wanted_cars) + trams
    end

    def populate_bay
      return @gulls.clear && @boats.clear if @water.empty?

      @gulls << spawn_gull while @gulls.size < GULLS
      @boats << spawn_boat while @boats.size < BOATS
    end

    def spawn_walker
      x, y = random_stand
      Walker.new(name: NAMES[@walkers.size % NAMES.size], sprite: @rng.rand(8), x: x, y: y, face: 1, path: [],
                 wait: 0, say: nil, say_until: 0, said_at: -SAY_AGAIN)
    end

    def spawn_car(tram: false)
      x, y = (tram ? @track : @roads).to_a.sample(random: @rng)
      Car.new(x: x, y: y, dx: 1, dy: 0, kind: tram ? "tram" : %w[red blue white yellow].sample(random: @rng))
    end

    def spawn_gull
      x, y = @water.sample(random: @rng)
      Gull.new(x: x, y: y, dx: [-1, 1].sample(random: @rng), dy: 0)
    end

    def spawn_boat
      x, y = @water.sample(random: @rng)
      Boat.new(x: x, y: y, dy: [-1, 1].sample(random: @rng))
    end

    # Somewhere to stand: a road cell, else free ground near the middle.
    def random_stand
      return @roads.to_a.sample(random: @rng) if @roads.any?

      20.times do
        cell = [(City::WIDTH / 2) + @rng.rand(-12..12), (City::HEIGHT / 2) + @rng.rand(-12..12)]
        return cell if @map.free?(*cell)
      end
      [City::WIDTH / 2, City::HEIGHT / 2]
    end

    # --- walking -------------------------------------------------------------

    def step_walker(walker, now)
      walker.say = nil if walker.say && now > walker.say_until
      if walker.wait.positive?
        walker.wait -= 1
        return
      end
      send_off(walker) if walker.path.empty?
      nxt = walker.path.shift or return
      return walker.path.clear unless walkable?(nxt)

      walker.face = nxt[0] <=> walker.x if nxt[0] != walker.x
      walker.x, walker.y = nxt
      walker.wait = @rng.rand(PAUSE) if walker.path.empty? && @stops.include?(nxt)
    end

    # On a road, a road cell to walk to: a shop or a park to stop at when
    # one is in reach, else anywhere. Off the roads, the nearest road when
    # there is one, else a stroll over the grass.
    def send_off(walker)
      from = [walker.x, walker.y]
      reached, target = if @roads.include?(from) then along_the_road(from)
                        elsif @roads.any? then toward_a_road(from)
                        else stroll(from)
                        end
      return walker.x, walker.y = random_stand if @roads.any? && !target

      walker.path = target ? trace(reached, target) : []
    end

    def along_the_road(from)
      reached = flood(from) { |c| @roads.include?(c) }
      stops = reached.keys & @stops.to_a
      [reached, (stops.any? && @rng.rand < 0.4 ? stops : reached.keys - [from]).sample(random: @rng)]
    end

    def toward_a_road(from)
      reached = flood(from) { |c| walkable?(c) }
      [reached, reached.keys.find { |c| @roads.include?(c) }]
    end

    def stroll(from)
      reached = flood(from, limit: 120) { |c| walkable?(c) }
      [reached, (reached.keys - [from]).sample(random: @rng)]
    end

    def walkable?(cell) = @roads.include?(cell) || @map.free?(*cell)

    # A breadth-first flood from `from` over cells the block allows, up to
    # `limit` cells or REACH steps out: each cell reached maps to the one
    # before it.
    def flood(from, limit: SEARCH)
      came_from = { from => nil }
      queue = [[from, 0]]
      while (cell, depth = queue.shift)
        break if came_from.size >= limit
        next if depth >= REACH

        @map.neighbors(*cell).each do |n|
          next if came_from.key?(n) || !yield(n)

          came_from[n] = cell
          queue << [n, depth + 1]
        end
      end
      came_from
    end

    def trace(came_from, cell)
      path = []
      while came_from[cell]
        path.unshift(cell)
        cell = came_from[cell]
      end
      path
    end

    # --- driving, flying, sailing -------------------------------------------

    # Straight on where the road goes on, else a turn, else back the way
    # it came. A cable car keeps to the track.
    def drive(car)
      lanes = car.kind == "tram" ? @track : @roads
      options = @map.neighbors(car.x, car.y).select { |c| lanes.include?(c) }
      return if options.empty?

      ahead = [car.x + car.dx, car.y + car.dy]
      nxt = choose_way(options, ahead, [car.x - car.dx, car.y - car.dy])
      car.dx = nxt[0] - car.x
      car.dy = nxt[1] - car.y
      car.x, car.y = nxt
    end

    def choose_way(options, ahead, back)
      turns = options - [ahead, back]
      return ahead if options.include?(ahead) && (turns.empty? || @rng.rand < 0.7)

      turns.any? ? turns.sample(random: @rng) : back
    end

    # Gulls wander, and drift back over the water when they stray.
    def fly(gull)
      gull.dy = @rng.rand(-1..1) if @rng.rand < 0.3
      gull.dx = -gull.dx if @rng.rand < 0.05
      gull.dx = 1 if strayed?(gull) && @rng.rand < 0.5
      gull.x = (gull.x + gull.dx).clamp(0, City::WIDTH - 1)
      gull.y = (gull.y + gull.dy).clamp(0, City::HEIGHT - 1)
      gull.dx = -gull.dx unless gull.x.between?(1, City::WIDTH - 2)
    end

    def strayed?(gull) = !@map.terrain.water?(gull.x, gull.y) && gull.x < City::WIDTH - 3

    # Boats run up and down the bay and turn where the water ends.
    def sail(boat)
      nxt = [boat.x, boat.y + boat.dy]
      if @map.in?(*nxt) && @map.water?(*nxt) then boat.y = nxt[1]
      else boat.dy = -boat.dy
      end
    end

    # A chimney lights or goes out now and then; new houses start lit half
    # the time; houses that are gone stop.
    def smoulder
      houses = @map.houses.map { |x, y| City.key(x, y) }
      @lit.select! { |k, _| houses.include?(k) }
      houses.each do |k|
        @lit[k] = @rng.rand < 0.5 unless @lit.key?(k)
        @lit[k] = !@lit[k] if @rng.rand < SMOKE_FLIP
      end
    end

    # --- talk ----------------------------------------------------------------

    # One bubble at a time, from a walker who has been quiet a while, about
    # what is around them.
    def speak(now)
      return if now - @last_say < SAY_EVERY

      walker = @walkers.select { |w| now - w.said_at > SAY_AGAIN }.sample(random: @rng) or return
      walker.say = line_for(walker)
      walker.say_until = now + SAY_FOR
      walker.said_at = now
      @last_say = now
    end

    def line_for(walker) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity -- one branch per thing worth remarking on
      cell = [walker.x, walker.y]
      near = ->(kinds, r) { @map.around(walker.x, walker.y, r).any? { |c| kinds.include?(@map[*c]) } }
      sign = @map.signs_at.find { |x, y, text| City.distance([x, y], cell) <= 2 && !text.to_s.strip.empty? }
      pool = if sign then ["it says: #{sign[2].to_s.strip[0, 16]}", "who put this sign here?"]
             elsif near.call([City::BRIDGE], 2) then ["nice bridge", "what a view!", "is it foggy out there?"]
             elsif near.call(City::SHOPS, 2) then ["fresh bread!", "coffee, finally", "is the shop open?"]
             elsif near.call([City::PARK], 2) then ["lovely park", "shall we picnic?", "the trees are nice"]
             elsif @track.include?(cell) then ["ding ding!", "hold on tight", "clang clang"]
             elsif @map.band(*cell) >= 2 then ["these hills!", "my legs...", "what a climb"]
             elsif @map.shops.empty? then ["where's the bakery?", "no shops yet?", "I could use a coffee"]
             elsif @roads.empty? then ["no roads yet", "someone build a road", "just grass so far"]
             else GENERIC
             end
      pool.sample(random: @rng)
    end
  end
end
