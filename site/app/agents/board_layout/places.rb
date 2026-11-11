class BoardLayout
  # Where things go: steps along a winding path, left to right and then
  # down and back, and notes in a grid. Each starts below what's placed.
  module Places
    private

    # Steps and notes each start below whatever is already placed.
    def switch_to(mode)
      return if @mode == mode

      top = @mode.nil? ? @oy + HEAD : @bottom + 90
      if mode == :steps
        @steps_top = top + 20
        @last = nil
      else
        @grid_top = top
        @grid = 0
      end
      @mode = mode
    end

    # The top left of the next note in the grid. A new group starts a row.
    def next_cell
      @grid += PER_ROW - (@grid % PER_ROW) if @new_row && (@grid % PER_ROW).positive?
      @new_row = false
      cell = @grid
      @grid += 1
      [@ox + ((cell % PER_ROW) * (Items::NOTE_W + GRID_GAP)),
       @grid_top + ((cell / PER_ROW) * (Items::NOTE_H + GRID_GAP))]
    end

    # Moves along the path to the next step's place, and keeps the stretch of
    # path that leads there in @segment. A full row, or a new group, turns
    # down to the next row, which runs the other way.
    def advance
      @steps = (@steps || 0) + 1
      return start_path if @last.nil?

      from = @last
      turning = @new_row || !(0...PER_ROW).cover?(@col + @dir)
      @new_row = false
      if turning
        turn = from[0] + (@dir * TURN)
        @row += 1
        @dir = -@dir
        @last = place
        @segment = path([from, [turn, from[1] + 40], [turn, @last[1] - 40], @last])
      else
        @col += @dir
        @last = place
        @segment = path([from, [(from[0] + @last[0]) / 2, from[1] + (@col.even? ? 26 : -26)], @last])
      end
    end

    def start_path
      @row = 0
      @col = 0
      @dir = 1
      @segment = nil
      @new_row = false
      @last = place
    end

    def place = [@ox + (@col * DX) + (DX / 2), @steps_top + (@row * DY)]
  end
end
