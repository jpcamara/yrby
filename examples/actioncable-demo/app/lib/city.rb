# frozen_string_literal: true

# The rules of the city: what a map of tiles is, and what a planner should
# build on it next. Nothing here knows about the document. CityPlanner reads
# the document into a Map, asks for the next Plan, and writes it back one
# cell at a time; CityLife reads the same Map to walk its townsfolk.
#
# A map is WIDTH x HEIGHT cells over a Terrain: a bay along the east edge
# and hills, both drawn from one seed, so every peer sees the same land
# without it being in the document. A cell holds one tile or nothing, which
# is whatever the terrain says: grass, or the bay. Roads, bridges, and cable
# car track carry traffic; houses, shops, parks, and signs are buildings;
# water is terrain a road can only cross on a bridge. A building wider than
# a cell is one key at its top-left cell, "name@WxH", and covers the rest.
# rubocop:disable-next Naming/MethodParameterName -- cells are x and y throughout
module City # rubocop:disable Metrics/ModuleLength -- the rules of the town, in one place
  WIDTH = 96
  HEIGHT = 96

  ROAD = "road"
  CABLE = "cable"
  WATER = "water"
  BRIDGE = "bridge"
  GRASS = "grass" # landfill: grass written over the bay
  SHOP = "shop"
  PARK = "park"
  SIGN = "sign"
  HOUSES = %w[house_red house_blue house_orange victorian_teal victorian_lilac victorian_cream grand cottage
              stone_cottage].freeze
  SHOPS = %w[shop shop_blue shop_green].freeze
  ROADS = [ROAD, BRIDGE, CABLE].freeze
  GROUND = [GRASS, "path", "plaza", "cobble"].freeze # walkable, buildable ground someone laid
  PROPS = %w[fence bench lamp flowers hydrant shrub mushrooms tree_small tree_orange_small pine tree_orange].freeze
  TILES = ([WATER, PARK, SIGN] + ROADS + GROUND + HOUSES + SHOPS + PROPS).freeze
  BUILDINGS = ([PARK, SIGN] + HOUSES + SHOPS).freeze
  CLEARABLE = ([PARK] + ROADS + SHOPS + GROUND - [GRASS]).freeze
  # Footprints, in cells, of what is wider than one.
  SIZES = { "shop" => [2, 2], "shop_blue" => [2, 2], "shop_green" => [2, 2], "victorian_teal" => [2, 2],
            "victorian_lilac" => [2, 2], "victorian_cream" => [2, 2], "cottage" => [2, 2], "stone_cottage" => [2, 2],
            "grand" => [2, 3] }.freeze

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

  # A tile value as [name, width, height]: "shop@2x2" is a shop over two
  # cells by two; "road" is one cell. Nil for anything the page could not
  # have written.
  def self.parse_tile(value)
    match = /\A([a-z_]+)(?:@([1-3])x([1-3]))?\z/.match(value.to_s) or return nil
    return nil unless TILES.include?(match[1])

    [match[1], (match[2] || 1).to_i, (match[3] || 1).to_i]
  end

  # The value the document holds for a tile: its name, and its footprint
  # when that is more than one cell.
  def self.sized(name)
    w, h = SIZES[name]
    w ? "#{name}@#{w}x#{h}" : name
  end

  # Chebyshev distance: the number of king's moves between two cells.
  def self.distance(a, b) = [(a[0] - b[0]).abs, (a[1] - b[1]).abs].max

  # True when any of `cells` lies within `radius` of any of `others`.
  def self.near?(cells, others, radius)
    cells.any? { |cell| others.any? { |other| distance(cell, other) <= radius } }
  end

  # --- the land ------------------------------------------------------------

  # The lie of the land under the tiles, from one seed: where the bay is
  # and how high each cell stands, in four bands. The page computes the
  # same numbers from the same seed, so the hash and the noise are written
  # to match its arithmetic exactly: 32-bit integer mixing, then doubles.
  class Terrain
    BAY = 9       # cells of water along the east edge, at least
    BAY_REACH = 7 # and up to this many more, by the noise
    FLAT_BY_BAY = 3

    # One terrain per seed, kept.
    def self.for(seed)
      return FLAT unless seed

      @for ||= {}
      @for[seed] ||= new(seed)
    end

    def self.hash32(x, y, s)
      h = ((x * 374_761_393) + (y * 668_265_263) + (s * 1_442_695_041)) & 0xffffffff
      h = ((h ^ (h >> 13)) * 1_274_126_177) & 0xffffffff
      h ^= h >> 16
      h / 4_294_967_296.0
    end

    # Value noise: the corners of the cell's grid square, blended.
    def self.noise(s, x, y, scale) # rubocop:disable Metrics/AbcSize -- term for term the page's arithmetic
      gx = (x / scale.to_f).floor
      gy = (y / scale.to_f).floor
      fx = (x / scale.to_f) - gx
      fy = (y / scale.to_f) - gy
      ux = fx * fx * (3 - (2 * fx))
      uy = fy * fy * (3 - (2 * fy))
      top = hash32(gx, gy, s) + ((hash32(gx + 1, gy, s) - hash32(gx, gy, s)) * ux)
      bottom = hash32(gx, gy + 1, s) + ((hash32(gx + 1, gy + 1, s) - hash32(gx, gy + 1, s)) * ux)
      top + ((bottom - top) * uy)
    end

    def self.elevation(seed, x, y) = (0.6 * noise(seed, x, y, 16)) + (0.4 * noise(seed + 1, x, y, 7))

    def initialize(seed)
      @seed = seed
      @shore = Array.new(HEIGHT) { |y| WIDTH - BAY - (Terrain.noise(seed + 2, y, 0, 8) * BAY_REACH).floor }
      @band = Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| band_of(x, y) } }
    end

    attr_reader :seed

    def water?(x, y) = x >= @shore[y]
    def band(x, y) = @band[y][x]

    # A step between two cells is steep when they stand in different bands.
    def steep?(a, b) = band(*a) != band(*b)

    # No seed: flat grass everywhere, the map the tests draw.
    FLAT = Object.new.tap do |flat|
      def flat.water?(_x, _y) = false
      def flat.band(_x, _y) = 0
      def flat.steep?(_a, _b) = false
      def flat.seed = nil
    end

    private

    def band_of(x, y)
      return 0 if x >= @shore[y] - FLAT_BY_BAY

      e = Terrain.elevation(@seed, x, y)
      if e < 0.38 then 0
      elsif e < 0.5 then 1
      elsif e < 0.62 then 2
      else 3
      end
    end
  end

  # What to build: a status label, and the cells in build order, each
  # [x, y, tile]. A nil tile means the cell is cleared back to what the
  # land is there.
  Plan = Data.define(:goal, :cells) do
    def id = "#{goal}@#{cells.first&.first(2)&.join(",")}"
    def cell_keys = cells.map { |x, y, _| City.key(x, y) }
    def positions = cells.map { |x, y, _| [x, y] }
  end

  # The characters Map.parse reads, one per cell.
  LEGEND = { "." => nil, "#" => ROAD, "~" => WATER, "=" => BRIDGE, "H" => HOUSES[0], "S" => "shop@2x2", "P" => PARK,
             "!" => SIGN, "V" => "victorian_teal@2x2", "%" => CABLE }.freeze

  # The tiles, the signs, the mayor's readings of signs the rules do not
  # understand, and the terrain's seed, the maps keyed "x,y". Anything the
  # page could not have written is dropped on the way in. `cover` maps each
  # cell under a wide building to the building's anchor.
  Map = Data.define(:tiles, :signs, :readings, :seed, :cover) do
    def self.empty = new({}, {}, {})

    def self.from(tiles, signs, readings = {}, seed: nil)
      kept = tiles.select { |k, v| City.parse_key(k) && City.parse_tile(v) }
      texts = signs.select { |k, v| City.parse_key(k) && v.is_a?(String) }
      read = readings.select { |k, v| City.parse_key(k) && v.is_a?(String) }
      new(tiles: kept, signs: texts, readings: read, seed: seed.is_a?(Integer) ? seed : nil)
    end

    # From rows of characters, for tests: "." grass, "#" road, "~" water,
    # "=" bridge, "H" house, "S" shop, "P" park, "!" sign, "V" a Victorian
    # over four cells, "%" cable car track. Signs get their text from
    # `signs`, keyed "x,y", and readings from `readings`.
    def self.parse(text, signs: {}, readings: {}, seed: nil)
      tiles = {}
      text.lines.map(&:chomp).each_with_index do |row, y|
        row.chars.each_with_index { |ch, x| tiles[City.key(x, y)] = LEGEND.fetch(ch) if LEGEND.fetch(ch) }
      end
      from(tiles, signs, readings, seed: seed)
    end

    def initialize(tiles:, signs:, readings: {}, seed: nil, cover: nil)
      super(tiles: tiles.freeze, signs: signs.freeze, readings: readings.freeze, seed: seed,
            cover: (cover || Map.cover_of(tiles)).freeze)
    end

    def self.cover_of(tiles)
      tiles.each_with_object({}) do |(k, v), cover|
        name, w, h = City.parse_tile(v)
        next unless name && (w > 1 || h > 1)

        x, y = City.parse_key(k)
        h.times { |dy| w.times { |dx| cover[City.key(x + dx, y + dy)] = k unless dx.zero? && dy.zero? } }
      end
    end

    def terrain = Terrain.for(seed)

    # The tile at a cell: its own, or that of the wide building over it.
    def [](x, y)
      value = tiles[City.key(x, y)] || tiles[cover[City.key(x, y)]]
      value && City.parse_tile(value)&.first
    end

    def in?(x, y) = x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)

    # Nothing built here, and land to build on.
    def free?(x, y) = in?(x, y) && ground?(x, y) && !water?(x, y)
    def ground?(x, y) = (tile = self[x, y]).nil? || GROUND.include?(tile)

    def water?(x, y)
      self[x, y] == WATER || (tiles[City.key(x, y)].nil? && !cover[City.key(x, y)] && terrain.water?(x, y))
    end

    def road?(x, y) = ROADS.include?(self[x, y])
    def house?(x, y) = HOUSES.include?(self[x, y])
    def shop?(x, y) = SHOPS.include?(self[x, y])
    def band(x, y) = terrain.band(x, y)
    def steep?(a, b) = terrain.steep?(a, b)

    # Anchors: the top-left cells of the houses, the shops, the roads.
    def houses = cells_with(HOUSES)
    def shops = cells_with(SHOPS)
    def parks = cells_with([PARK])
    def roads = cells_with(ROADS)
    def signs_at = signs.filter_map { |k, text| City.parse_key(k)&.then { |x, y| [x, y, text] } }

    # The cells of the building at a cell, the cell alone when nothing wide
    # stands there.
    def footprint(x, y)
      k = City.key(x, y)
      anchor = tiles[k] ? k : cover[k]
      return [[x, y]] unless anchor

      ax, ay = City.parse_key(anchor)
      _, w, h = City.parse_tile(tiles[anchor])
      (ay...(ay + h)).flat_map { |fy| (ax...(ax + w)).map { |fx| [fx, fy] } }
    end

    # The cells around a building, outside it and in bounds.
    def beside(x, y)
      inside = footprint(x, y)
      inside.flat_map { |c| neighbors(*c) }.uniq - inside
    end

    # All the cells a building of `w` by `h` at `x, y` would cover, in bounds.
    def cells_of(x, y, w, h)
      cells = (y...(y + h)).flat_map { |fy| (x...(x + w)).map { |fx| [fx, fy] } }
      cells.all? { |c| in?(*c) } ? cells : nil
    end

    # True when a building of that size fits at the cell: every cell free
    # and none blocked.
    def fits?(x, y, tile, blocked = Set.new)
      _, w, h = City.parse_tile(City.sized(tile))
      cells = cells_of(x, y, w, h) or return false
      cells.all? { |c| free?(*c) && !blocked.include?(c) }
    end

    # True when a building of `tile` at the cell would stand beside a road.
    def road_by?(x, y, tile)
      _, w, h = City.parse_tile(City.sized(tile))
      cells = cells_of(x, y, w, h) or return false
      (cells.flat_map { |c| neighbors(*c) } - cells).any? { |c| road?(*c) }
    end

    # What the sign at a cell asks for: what its text says, else what the
    # mayor read into it.
    def instruction_at(x, y)
      City.instruction(signs[City.key(x, y)]) || City.instruction(readings[City.key(x, y)])
    end

    # Signs that only name something: no instruction in the text or read
    # into it, and not a request for a name either.
    def name_signs = signs_at.reject { |x, y, _| instruction_at(x, y) || wish?(x, y) }

    # A sign the mayor read as asking for a particular name.
    def wish?(x, y) = readings[City.key(x, y)] == "NAME"

    def cells_with(kinds)
      tiles.filter_map { |k, v| City.parse_key(k) if kinds.include?(City.parse_tile(v)&.first) }.sort
    end

    def neighbors(x, y)
      [[x, y - 1], [x + 1, y], [x, y + 1], [x - 1, y]].select { |nx, ny| in?(nx, ny) }
    end

    # Every cell within `radius` king's moves, the center included.
    def around(x, y, radius)
      ((y - radius)..(y + radius)).flat_map { |ny| ((x - radius)..(x + radius)).map { |nx| [nx, ny] } }
                                  .select { |c| in?(*c) }
    end

    def touches_road?(x, y) = beside(x, y).any? { |c| road?(*c) }

    # The map after a plan is built: what the planner would see next.
    def with(cells)
      changed = tiles.dup
      cells.each { |x, y, tile| tile ? changed[City.key(x, y)] = tile : changed.delete(City.key(x, y)) }
      Map.new(tiles: changed, signs: signs, readings: readings, seed: seed)
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
  # closer, crossing water on bridges and climbing hills on cable car track.
  def self.road_plans(map, blocked)
    map.houses.reject { |x, y| map.touches_road?(x, y) }
       .filter_map { |house| road_plan(map, house, blocked, "laying road") }
       .uniq { |plan| plan.positions.sort }
       .sort_by { |plan| [plan.cells.size, plan.cells.first] }
  end

  def self.road_plan(map, from, blocked, goal)
    targets = road_targets(map, from, blocked)
    return if targets.empty?

    path = Path.find(map, map.footprint(*from), targets, blocked) or return
    return if path.empty?

    cells = path.zip(surfaces(map, path)).map { |(x, y), tile| [x, y, tile] }
    goal = "building bridge" if cells.any? { |_, _, tile| tile == BRIDGE }
    goal = "laying cable car track" if goal == "laying road" && cells.any? { |_, _, tile| tile == CABLE }
    Plan.new(goal, cells)
  end

  # What each cell of a path is paved with: a bridge over water, cable car
  # track on both sides of a steep step, road otherwise.
  def self.surfaces(map, path)
    tiles = path.map { |x, y| map.water?(x, y) ? BRIDGE : ROAD }
    path.each_cons(2).with_index do |(a, b), i|
      next unless map.steep?(a, b) && tiles[i] == ROAD && tiles[i + 1] == ROAD

      tiles[i] = tiles[i + 1] = CABLE
    end
    tiles
  end

  # Where a road from `from` may end: a road cell, or a free cell beside
  # another house.
  def self.road_targets(map, from, blocked)
    others = map.houses - [from]
    beside = others.flat_map { |x, y| map.beside(x, y) }.select { |c| passable?(map, c, blocked) }
    Set.new(map.roads) | beside
  end

  def self.passable?(map, cell, blocked)
    (map.free?(*cell) || map.water?(*cell)) && !blocked.include?(cell)
  end

  # --- shops ---------------------------------------------------------------

  # A district is the houses on one road network. One with DISTRICT_SIZE
  # houses and no shop gets a shop on free cells by its roads, as near the
  # middle of the district as there is room.
  def self.shop_plans(map, blocked)
    districts(map).filter_map do |roads, houses|
      next if houses.size < DISTRICT_SIZE || roads.any? { |x, y| map.neighbors(x, y).any? { |c| map.shop?(*c) } }

      site = sites(map, roadside(map, roads, blocked), SHOP, blocked).min_by { |c| distance_sum(c, houses) } or next
      Plan.new("opening a shop", [[*site, sized(SHOP)]])
    end
  end

  # Road networks and the houses beside each: [[road cells], [house cells]].
  def self.districts(map)
    components(map.roads).map do |roads|
      beside = Set.new(roads.flat_map { |x, y| map.neighbors(x, y) })
      [roads, map.houses.select { |house| map.footprint(*house).any? { |c| beside.include?(c) } }]
    end
  end

  def self.roadside(map, roads, blocked)
    roads.flat_map { |x, y| map.neighbors(x, y) }.uniq.select { |c| map.free?(*c) && !blocked.include?(c) }
  end

  # The anchors at which `tile` fits with one of its cells on a candidate:
  # for a wide building, every anchor that puts a cell of it there.
  def self.sites(map, candidates, tile, blocked)
    _, w, h = parse_tile(sized(tile))
    candidates.flat_map { |x, y| (0...h).flat_map { |dy| (0...w).map { |dx| [x - dx, y - dy] } } }
              .uniq.select { |x, y| map.fits?(x, y, tile, blocked) }
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
  # more, fullest first. Counted with a summed-area table, so the whole
  # map costs one pass.
  def self.dense_windows(map)
    sum = summed_houses(map)
    count = lambda do |left, top|
      sum[top + BLOCK][left + BLOCK] - sum[top][left + BLOCK] - sum[top + BLOCK][left] + sum[top][left]
    end
    counted = (0..(HEIGHT - BLOCK)).flat_map do |top|
      (0..(WIDTH - BLOCK)).map { |left| [count.call(left, top), left, top] }
    end
    counted.select { |count, _, _| count >= BLOCK_HOUSES }.sort_by { |count, left, top| [-count, top, left] }
           .map { |_, left, top| [left, top] }
  end

  # sum[y][x] is the number of houses anchored above and left of the cell.
  def self.summed_houses(map)
    houses = Set.new(map.houses)
    sum = Array.new(HEIGHT + 1) { Array.new(WIDTH + 1, 0) }
    HEIGHT.times do |y|
      WIDTH.times do |x|
        sum[y + 1][x + 1] = sum[y][x + 1] + sum[y + 1][x] - sum[y][x] + (houses.include?([x, y]) ? 1 : 0)
      end
    end
    sum
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

  # One building within reach of the sign, nearest it, unless one is there
  # already. A shop prefers a site by a road.
  def self.place_plan(map, sign, tile, goal, blocked)
    x, y = sign
    cells = map.around(x, y, SIGN_REACH)
    kinds = tile == SHOP ? SHOPS : [tile]
    return if cells.any? { |c| kinds.include?(map[*c]) }

    site = sites(map, cells, tile, blocked)
           .min_by { |c| [tile == SHOP && !map.road_by?(*c, tile) ? 1 : 0, distance_sum(c, [sign]), c] } or return
    Plan.new(goal, [[*site, sized(tile)]])
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
    while map.in?(*cell) && map.water?(*cell) && !blocked.include?(cell)
      cells << [*cell, BRIDGE]
      cell = [cell[0] + step[0], cell[1] + step[1]]
    end
    Plan.new("building bridge", cells) if cells.any?
  end

  # Clear what the planner or anyone laid within reach of the sign: roads,
  # bridges, track, shops, parks, paths. Houses, signs, props, and water stay.
  def self.clear_plan(map, sign)
    x, y = sign
    cells = map.around(x, y, SIGN_REACH).select { |c| map.tiles.key?(key(*c)) && CLEARABLE.include?(map[*c]) }
               .map { |cx, cy| [cx, cy, nil] }
    Plan.new("clearing", cells) if cells.any?
  end

  # --- names ---------------------------------------------------------------

  NAME_ROAD = 8    # road cells before a road is a street worth naming
  NAME_HOUSES = 4  # houses on a road network before it is a neighbourhood

  # Where a name is missing: each road network with NAME_HOUSES houses, or
  # NAME_ROAD cells, that has no name sign beside it, as [kind, site], the
  # site a free cell by the road nearest the middle of what it names, and
  # not up against a house when there is room. A sign anyone placed counts
  # as its name. A network someone asked a name for comes first.
  def self.naming_sites(map, blocked = Set.new)
    named = Set.new(map.name_signs.flat_map { |x, y, _| map.neighbors(x, y) })
    sites = districts(map).filter_map do |roads, houses|
      next if roads.any? { |cell| named.include?(cell) }

      kind = naming_kind(roads, houses) or next
      site = roadside(map, roads, blocked).min_by do |c|
        [map.neighbors(*c).any? { |n| map.house?(*n) } ? 1 : 0, distance_sum(c, kind == "district" ? houses : roads)]
      end
      [kind, site] if site
    end
    wished_first(map, sites)
  end

  def self.wished_first(map, sites)
    sites.sort_by.with_index { |(_, site), i| [naming_wishes(map, site).any? ? 0 : 1, i] }
  end

  def self.naming_kind(roads, houses)
    if houses.size >= NAME_HOUSES then "district"
    elsif roads.size >= NAME_ROAD then "street"
    end
  end

  # What the signs beside the road network a site names say, as their
  # texts: a sign that asks for a particular name is a wish the mayor
  # takes into account.
  def self.naming_wishes(map, site)
    network = components(map.roads).find { |roads| map.neighbors(*site).any? { |c| roads.include?(c) } } or return []
    map.signs_at.select { |x, y, _| map.neighbors(x, y).any? { |c| network.include?(c) } }.map(&:last)
  end

  # Shortest paths over grass and water, water costing WATER_COST per
  # cell, around buildings and blocked cells. Dijkstra with buckets, since
  # the costs are small integers.
  module Path
    module_function

    # The cells from beside any of `starts` up to and including the first
    # target reached, in walking order; a target that is already a road is
    # not included, since there is nothing to build there. Nil when no
    # target can be reached.
    def find(map, starts, targets, blocked)
      came_from = starts.to_h { |cell| [cell, nil] }
      buckets = Hash.new { |h, k| h[k] = [] }
      buckets[0].concat(starts)
      cost = 0
      while cost <= WIDTH * HEIGHT * WATER_COST
        bucket = buckets.delete(cost) || []
        while (cell = bucket.shift)
          return trace(map, came_from, cell) if targets.include?(cell) && !starts.include?(cell)

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

    def trace(map, came_from, cell)
      path = []
      while came_from[cell]
        path.unshift(cell)
        cell = came_from[cell]
      end
      path.pop if path.any? && map.road?(*path.last)
      path
    end
  end
end
