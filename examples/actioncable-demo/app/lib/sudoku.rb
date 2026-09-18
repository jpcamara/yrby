# frozen_string_literal: true

# The rules of sudoku on a grid of 81 digits: which cells clash, whether the
# grid is solved, how to solve it, how to make a puzzle with one solution,
# and where a hint goes. Nothing here knows about the document. SudokuPeer
# reads the document into a Grid and writes back what these say.
module Sudoku
  SIZE = 9
  CELLS = SIZE * SIZE
  DIGITS = (1..SIZE).to_a.freeze
  # A cell's key in the document: "r0c0" at the top left through "r8c8".
  KEYS = (0...SIZE).flat_map { |r| (0...SIZE).map { |c| "r#{r}c#{c}" } }.freeze
  # The cells that share a row, column, or box with each cell, without it.
  PEERS = (0...CELLS).map do |i|
    r, c = i.divmod(SIZE)
    (0...CELLS).select do |j|
      jr, jc = j.divmod(SIZE)
      j != i && (jr == r || jc == c || (jr / 3 == r / 3 && jc / 3 == c / 3))
    end.freeze
  end.freeze

  def self.key(index) = KEYS.fetch(index)
  def self.index(key) = KEYS.index(key)

  # 81 digits in row order, 0 for an empty cell.
  Grid = Data.define(:digits) do
    def self.empty = new(Array.new(CELLS, 0))

    # From text like "53..7....", one character per cell: a digit, or "." or
    # "0" for an empty cell. Whitespace is ignored.
    def self.parse(text)
      chars = text.gsub(/\s/, "").chars
      raise ArgumentError, "a grid is #{CELLS} cells, not #{chars.size}" unless chars.size == CELLS

      new(chars.map { |ch| ch.match?(/[1-9]/) ? ch.to_i : 0 })
    end

    # From a document map, {"r0c0" => 5}. A key that is not a cell, or a
    # value that is not a digit 1-9, is an empty cell.
    def self.from_map(map)
      digits = Array.new(CELLS, 0)
      map.each do |key, value|
        index = Sudoku.index(key.to_s) or next
        digits[index] = value if DIGITS.include?(value)
      end
      new(digits)
    end

    def initialize(digits:) = super(digits: digits.freeze)

    def [](index) = digits[index]
    def with(index, digit) = Grid.new(digits.dup.tap { |d| d[index] = digit })
    # This grid's digits, and the other's where this one is empty.
    def merge(other) = Grid.new(digits.each_with_index.map { |d, i| d.zero? ? other[i] : d })
    def filled = digits.count(&:positive?)
    def complete? = digits.none?(&:zero?)
    def empty_cells = digits.each_index.select { |i| digits[i].zero? }
    def to_map = digits.each_with_index.reject { |d, _| d.zero? }.to_h { |d, i| [Sudoku.key(i), d] }
    def to_s = digits.each_slice(SIZE).map { |row| row.map { |d| d.zero? ? "." : d }.join }.join("\n")

    # The cells whose digit appears again in their row, column, or box.
    def conflicts
      digits.each_index.select { |i| digits[i].positive? && PEERS[i].any? { |j| digits[j] == digits[i] } }
    end

    def solved? = complete? && conflicts.empty?

    # The digits that could go in a cell without a clash.
    def candidates(index) = DIGITS - PEERS[index].map { |j| digits[j] }

    # The first solution found, or nil. `order` is the order digits are
    # tried in; a shuffled one makes a random solution of an empty grid.
    def solve(order: DIGITS) = solutions(limit: 1, order: order).first

    # Up to `limit` solutions. Filling the cell with the fewest candidates
    # first keeps the search short.
    def solutions(limit: 2, order: DIGITS)
      return conflicts.empty? ? [self] : [] if complete?

      index = empty_cells.min_by { |i| candidates(i).size }
      found = []
      (order & candidates(index)).each do |digit|
        found.concat(with(index, digit).solutions(limit: limit - found.size, order: order))
        break if found.size >= limit
      end
      found
    end
  end

  Puzzle = Data.define(:givens, :solution)

  # A puzzle with one solution: a random solved grid with cells taken out
  # one at a time, in random order, as long as the solution stays the only
  # one, down to `givens` cells.
  def self.generate(givens: 34, random: Random.new)
    solution = Grid.empty.solve(order: DIGITS.shuffle(random: random))
    grid = solution
    (0...CELLS).to_a.shuffle(random: random).each do |index|
      break if grid.filled <= givens

      fewer = grid.with(index, 0)
      grid = fewer if fewer.solutions(limit: 2).size == 1
    end
    Puzzle.new(givens: grid, solution: solution)
  end

  # Where a hint goes: the first empty cell, else the first cell that is
  # not what the solution says, else nowhere.
  def self.hint(grid, solution)
    grid.empty_cells.first || grid.digits.each_index.find { |i| grid[i] != solution[i] }
  end
end
