# frozen_string_literal: true

# The rules of the city: what a map of tiles is, and what a planner should
# build on it next. Nothing here knows about the document. CityPlanner reads
# the document into a Map, asks for the next Plan, and writes it back one
# cell at a time.
#
# A map is WIDTH x HEIGHT cells. A cell holds one tile or nothing, which is
# grass. Roads and bridges carry traffic; houses, shops, parks, and signs
# are buildings; water is terrain a road can only cross on a bridge.
# rubocop:disable-next Naming/MethodParameterName -- cells are x and y throughout
module City
  WIDTH = 48
  HEIGHT = 48

  ROAD = "road"
  WATER = "water"
  BRIDGE = "bridge"
  SHOP = "shop"
  PARK = "park"
  SIGN = "sign"
  HOUSES = %w[house_red house_blue house_orange].freeze
  TILES = ([ROAD, WATER, BRIDGE, SHOP, PARK, SIGN] + HOUSES).freeze
  BUILDINGS = ([SHOP, PARK, SIGN] + HOUSES).freeze
  CLEARABLE = [ROAD, BRIDGE, SHOP, PARK].freeze

  WATER_COST = 3     # a bridge cell counts as this many road cells when a path is chosen
  DISTRICT_SIZE = 10 # houses on one road network before it needs a shop
  BLOCK = 6          # the side of the window a dense block is measured in
  BLOCK_HOUSES = 8   # houses in one window before it needs a park
  SIGN_REACH = 2     # how far from a sign its instruction applies
  NO_BUILD_REACH = 3 # how far a NO BUILD sign keeps the planner away

  # Cell keys are "x,y", as the page writes them.
  def self.key(x, y) = "#{x},#{y}"

  def self.parse_key(key)
    match = /\A(\d{1,2}),(\d{1,2})\z/.match(key.to_s) or return nil
    cell = [match[1].to_i, match[2].to_i]
    cell if cell[0] < WIDTH && cell[1] < HEIGHT
  end

  # Chebyshev distance: the number of king's moves between two cells.
  def self.distance(a, b) = [(a[0] - b[0]).abs, (a[1] - b[1]).abs].max

  # True when any of `cells` lies within `radius` of any of `others`.
  def self.near?(cells, others, radius)
    cells.any? { |cell| others.any? { |other| distance(cell, other) <= radius } }
  end

  # What to build: a status label, and the cells in build order, each
  # [x, y, tile]. A nil tile means the cell is cleared back to grass.
  Plan = Data.define(:goal, :cells) do
    def id = "#{goal}@#{cells.first&.first(2)&.join(",")}"
    def cell_keys = cells.map { |x, y, _| City.key(x, y) }
    def positions = cells.map { |x, y, _| [x, y] }
  end

  # The characters Map.parse reads, one per cell.
  LEGEND = { "." => nil, "#" => ROAD, "~" => WATER, "=" => BRIDGE, "H" => HOUSES[0], "S" => SHOP, "P" => PARK,
             "!" => SIGN }.freeze

  # The tiles, the signs, and the mayor's readings of signs the rules do not
  # understand, as hashes keyed "x,y". Anything the page could not have
  # written is dropped on the way in.
  Map = Data.define(:tiles, :signs, :readings) do
    def self.empty = new({}, {}, {})

    def self.from(tiles, signs, readings = {})
      kept = tiles.select { |k, v| City.parse_key(k) && TILES.include?(v) }
      texts = signs.select { |k, v| City.parse_key(k) && v.is_a?(String) }
      read = readings.select { |k, v| City.parse_key(k) && v.is_a?(String) }
      new(kept.freeze, texts.freeze, read.freeze)
    end

    # From rows of characters, for tests: "." grass, "#" road, "~" water,
    # "=" bridge, "H" house, "S" shop, "P" park, "!" sign. Signs get their
    # text from `signs`, keyed "x,y", and readings from `readings`.
    def self.parse(text, signs: {}, readings: {})
      tiles = {}
      text.lines.map(&:chomp).each_with_index do |row, y|
        row.chars.each_with_index { |ch, x| tiles[City.key(x, y)] = LEGEND.fetch(ch) if LEGEND.fetch(ch) }
      end
      from(tiles, signs, readings)
    end

    def initialize(tiles:, signs:, readings: {})
      super(tiles: tiles.freeze, signs: signs.freeze, readings: readings.freeze)
    end

    def [](x, y) = tiles[City.key(x, y)]
    def in?(x, y) = x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)
    def free?(x, y) = in?(x, y) && self[x, y].nil?
    def water?(x, y) = self[x, y] == WATER
    def road?(x, y) = [ROAD, BRIDGE].include?(self[x, y])
    def house?(x, y) = HOUSES.include?(self[x, y])
    def houses = cells_with(HOUSES)
    def roads = cells_with([ROAD, BRIDGE])
    def signs_at = signs.filter_map { |k, text| City.parse_key(k)&.then { |x, y| [x, y, text] } }

    # What the sign at a cell asks for: what its text says, else what the
    # mayor read into it.
    def instruction_at(x, y)
      City.instruction(signs[City.key(x, y)]) || City.instruction(readings[City.key(x, y)])
    end

    # Signs that only name something: no instruction in the text or read
    # into it.
    def name_signs = signs_at.reject { |x, y, _| instruction_at(x, y) }

    def cells_with(kinds)
      tiles.filter_map { |k, tile| City.parse_key(k) if kinds.include?(tile) }.sort
    end

    def neighbors(x, y)
      [[x, y - 1], [x + 1, y], [x, y + 1], [x - 1, y]].select { |nx, ny| in?(nx, ny) }
    end

    # Every cell within `radius` king's moves, the center included.
    def around(x, y, radius)
      ((y - radius)..(y + radius)).flat_map { |ny| ((x - radius)..(x + radius)).map { |nx| [nx, ny] } }
                                  .select { |c| in?(*c) }
    end

    def touches_road?(x, y) = neighbors(x, y).any? { |c| road?(*c) }

    # The map after a plan is built: what the planner would see next.
    def with(cells)
      changed = tiles.dup
      cells.each { |x, y, tile| tile ? changed[City.key(x, y)] = tile : changed.delete(City.key(x, y)) }
      Map.new(changed, signs, readings)
    end
  end

  # The cells a planner must leave alone: within reach of a NO BUILD sign,
  # and whatever `avoid` names, such as cells people wrote to just now.
  def self.blocked(map, avoid = [])
    zones = map.signs_at.select { |x, y, _| map.instruction_at(x, y) == :no_build }
    Set.new(avoid) | zones.flat_map { |x, y, _| map.around(x, y, NO_BUILD_REACH) }
  end

  # What a sign asks for, or nil for a sign that is only a sign.
  def self.instruction(text)
    words = text.to_s.upcase
    return :no_build if words.include?("NO BUILD")

    %i[park shop road bridge clear].find { |word| words.match?(/\b#{word.to_s.upcase}\b/) }
  end

  # Everything worth doing, most pressing first: what signs ask for, then
  # roads to houses that have none, then a shop for a district that has
  # grown, then a park for a crowded block.
  def self.plans(map, avoid = [])
    blocked = blocked(map, avoid)
    sign_plans(map, blocked) + road_plans(map, blocked) + shop_plans(map, blocked) + park_plans(map, blocked)
  end

  def self.next_plan(map, avoid = []) = plans(map, avoid).first

  # --- roads ---------------------------------------------------------------

  # A road from every house that touches none, shortest first. The road
  # goes to the nearest road or the nearest other house, whichever is
  # closer, crossing water on bridges.
  def self.road_plans(map, blocked)
    map.houses.reject { |x, y| map.touches_road?(x, y) }
       .filter_map { |house| road_plan(map, house, blocked, "laying road") }
       .uniq { |plan| plan.positions.sort }
       .sort_by { |plan| [plan.cells.size, plan.cells.first] }
  end

  def self.road_plan(map, from, blocked, goal)
    targets = road_targets(map, from, blocked)
    return if targets.empty?

    path = Path.find(map, from, targets, blocked) or return
    cells = path.map { |x, y| [x, y, map.water?(x, y) ? BRIDGE : ROAD] }
    return if cells.empty?

    goal = "building bridge" if cells.any? { |_, _, tile| tile == BRIDGE }
    Plan.new(goal, cells)
  end

  # Where a road from `from` may end: a road cell, or a free cell beside
  # another house.
  def self.road_targets(map, from, blocked)
    others = map.houses - [from]
    beside = others.flat_map { |x, y| map.neighbors(x, y) }.select { |c| passable?(map, c, blocked) }
    Set.new(map.roads) | beside
  end

  def self.passable?(map, cell, blocked)
    (map.free?(*cell) || map.water?(*cell)) && !blocked.include?(cell)
  end

  # --- shops ---------------------------------------------------------------

  # A district is the houses on one road network. One with DISTRICT_SIZE
  # houses and no shop gets a shop on a free cell by its roads, as near the
  # middle of the district as there is one.
  def self.shop_plans(map, blocked)
    districts(map).filter_map do |roads, houses|
      next if houses.size < DISTRICT_SIZE || roads.any? { |x, y| map.neighbors(x, y).any? { |c| map[*c] == SHOP } }

      site = roadside(map, roads, blocked).min_by { |c| distance_sum(c, houses) } or next
      Plan.new("opening a shop", [[*site, SHOP]])
    end
  end

  # Road networks and the houses beside each: [[road cells], [house cells]].
  def self.districts(map)
    components(map.roads).map do |roads|
      beside = Set.new(roads.flat_map { |x, y| map.neighbors(x, y) })
      [roads, map.houses.select { |house| beside.include?(house) }]
    end
  end

  def self.roadside(map, roads, blocked)
    roads.flat_map { |x, y| map.neighbors(x, y) }.uniq.select { |c| map.free?(*c) && !blocked.include?(c) }
  end

  def self.distance_sum(cell, cells) = cells.sum { |other| (cell[0] - other[0]).abs + (cell[1] - other[1]).abs }

  # Connected groups of cells, four ways.
  def self.components(cells)
    left = Set.new(cells)
    groups = []
    until left.empty?
      queue = [left.first]
      left.delete(queue.first)
      group = []
      while (cell = queue.shift)
        group << cell
        x, y = cell
        [[x, y - 1], [x + 1, y], [x, y + 1], [x - 1, y]].each { |n| queue << n if left.delete?(n) }
      end
      groups << group.sort
    end
    groups
  end

  # --- parks ---------------------------------------------------------------

  # A BLOCK x BLOCK window with BLOCK_HOUSES houses and no park gets one, on
  # the free cell nearest the window's middle. The fullest window first.
  def self.park_plans(map, blocked)
    dense_windows(map).filter_map do |left, top|
      cells = window_cells(left, top)
      next if cells.any? { |c| map[*c] == PARK }

      site = park_site(map, cells, left, top, blocked) or next
      Plan.new("planting a park", [[*site, PARK]])
    end.uniq(&:cells)
  end

  # The top-left corners of the windows that hold BLOCK_HOUSES houses or
  # more, fullest first.
  def self.dense_windows(map)
    houses = Set.new(map.houses)
    corners = (0..(HEIGHT - BLOCK)).flat_map { |top| (0..(WIDTH - BLOCK)).map { |left| [left, top] } }
    counted = corners.map { |left, top| [window_cells(left, top).count { |c| houses.include?(c) }, left, top] }
    counted.select { |count, _, _| count >= BLOCK_HOUSES }.sort_by { |count, left, top| [-count, top, left] }
           .map { |_, left, top| [left, top] }
  end

  def self.park_site(map, cells, left, top, blocked)
    middle = [left + (BLOCK / 2.0) - 0.5, top + (BLOCK / 2.0) - 0.5]
    cells.select { |c| map.free?(*c) && !blocked.include?(c) }
         .min_by { |x, y| (x - middle[0]).abs + (y - middle[1]).abs }
  end

  def self.window_cells(left, top)
    (top...(top + BLOCK)).flat_map { |y| (left...(left + BLOCK)).map { |x| [x, y] } }
  end

  # --- signs ---------------------------------------------------------------

  # What signs ask for, in reading order. A sign whose wish is already true
  # asks for nothing more.
  def self.sign_plans(map, blocked)
    map.signs_at.sort_by { |x, y, _| [y, x] }.filter_map do |x, y, _|
      case map.instruction_at(x, y)
      when :park then place_plan(map, [x, y], PARK, "planting a park", blocked)
      when :shop then place_plan(map, [x, y], SHOP, "opening a shop", blocked)
      when :road then road_plan(map, [x, y], blocked, "laying road") unless map.touches_road?(x, y)
      when :bridge then bridge_plan(map, [x, y], blocked)
      when :clear then clear_plan(map, [x, y])
      end
    end
  end

  # One tile within reach of the sign, nearest it, unless one is there
  # already. A shop prefers a cell by a road.
  def self.place_plan(map, sign, tile, goal, blocked)
    x, y = sign
    cells = map.around(x, y, SIGN_REACH)
    return if cells.any? { |c| map[*c] == tile }

    site = cells.select { |c| map.free?(*c) && !blocked.include?(c) }
                .min_by { |c| [tile == SHOP && !map.touches_road?(*c) ? 1 : 0, distance_sum(c, [sign]), c] } or return
    Plan.new(goal, [[*site, tile]])
  end

  # A bridge straight across the water next to the sign, from the water's
  # near edge to its far one, unless the sign already has a bridge beside it.
  def self.bridge_plan(map, sign, blocked)
    x, y = sign
    return if map.neighbors(x, y).any? { |c| map[*c] == BRIDGE }

    start = map.neighbors(x, y).find { |c| map.water?(*c) } or return
    step = [start[0] - x, start[1] - y]
    cells = []
    cell = start
    while map.water?(*cell) && !blocked.include?(cell)
      cells << [*cell, BRIDGE]
      cell = [cell[0] + step[0], cell[1] + step[1]]
    end
    Plan.new("building bridge", cells) if cells.any?
  end

  # Clear what the planner or anyone laid within reach of the sign: roads,
  # bridges, shops, and parks. Houses, signs, and water stay.
  def self.clear_plan(map, sign)
    x, y = sign
    cells = map.around(x, y, SIGN_REACH).select { |c| CLEARABLE.include?(map[*c]) }.map { |cx, cy| [cx, cy, nil] }
    Plan.new("clearing", cells) if cells.any?
  end

  # --- names ---------------------------------------------------------------

  NAME_ROAD = 8    # road cells before a road is a street worth naming
  NAME_HOUSES = 4  # houses on a road network before it is a neighbourhood

  # Where a name is missing: each road network with NAME_HOUSES houses, or
  # NAME_ROAD cells, that has no name sign beside it, as [kind, site], the
  # site a free cell by the road nearest the middle of what it names, and
  # not up against a house when there is room. A sign anyone placed counts
  # as its name.
  def self.naming_sites(map, blocked = Set.new)
    named = Set.new(map.name_signs.flat_map { |x, y, _| map.neighbors(x, y) })
    districts(map).filter_map do |roads, houses|
      next if roads.any? { |cell| named.include?(cell) }

      kind = naming_kind(roads, houses) or next
      site = roadside(map, roads, blocked).min_by do |c|
        [map.neighbors(*c).any? { |n| map.house?(*n) } ? 1 : 0, distance_sum(c, kind == "district" ? houses : roads)]
      end
      [kind, site] if site
    end
  end

  def self.naming_kind(roads, houses)
    if houses.size >= NAME_HOUSES then "district"
    elsif roads.size >= NAME_ROAD then "street"
    end
  end

  # Shortest paths over grass and water, water costing WATER_COST per
  # cell, around buildings and blocked cells. Dijkstra with buckets, since
  # the costs are small integers.
  module Path
    module_function

    # The cells from beside `from` up to and including the first target
    # reached, in walking order; a target that is already a road is not
    # included, since there is nothing to build there. Nil when no target
    # can be reached.
    def find(map, from, targets, blocked)
      came_from = { from => nil }
      buckets = Hash.new { |h, k| h[k] = [] }
      buckets[0] << from
      cost = 0
      while cost <= WIDTH * HEIGHT * WATER_COST
        bucket = buckets.delete(cost) || []
        while (cell = bucket.shift)
          return trace(map, came_from, cell, from) if targets.include?(cell) && cell != from

          step(map, cell, came_from, buckets, cost, blocked, targets)
        end
        cost += 1
      end
      nil
    end

    def step(map, cell, came_from, buckets, cost, blocked, targets) # rubocop:disable Metrics/ParameterLists -- the search state
      map.neighbors(*cell).each do |nxt|
        next if came_from.key?(nxt)
        next unless targets.include?(nxt) || City.passable?(map, nxt, blocked)

        came_from[nxt] = cell
        buckets[cost + (map.water?(*nxt) ? WATER_COST : 1)] << nxt
      end
    end

    def trace(map, came_from, cell, from)
      path = []
      until cell == from
        path.unshift(cell)
        cell = came_from[cell]
      end
      path.pop if map.road?(*path.last)
      path
    end
  end
end
