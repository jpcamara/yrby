# frozen_string_literal: true

# The sudoku tests load the rules and the checker without booting Rails:
# they need yrby and the cable client, nothing of the app's.
#
#   bundle exec ruby -Itest test/sudoku_test.rb
#   bundle exec ruby -Itest test/sudoku_peer_test.rb
require "minitest/autorun"
require "y"
require_relative "../app/lib/sudoku"
require_relative "../app/lib/sudoku_peer"

module SudokuFixture
  PUZZLE = Sudoku::Grid.parse(<<~GRID)
    53..7....
    6..195...
    .98....6.
    8...6...3
    4..8.3..1
    7...2...6
    .6....28.
    ...419..5
    ....8..79
  GRID

  SOLUTION = Sudoku::Grid.parse(<<~GRID)
    534678912
    672195348
    198342567
    859761423
    426853791
    713924856
    961537284
    287419635
    345286179
  GRID
end
