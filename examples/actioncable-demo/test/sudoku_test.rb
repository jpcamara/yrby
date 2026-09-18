# frozen_string_literal: true

require "sudoku_helper"

class SudokuTest < Minitest::Test
  include SudokuFixture

  def test_a_known_puzzle_solves_to_its_solution
    assert_equal SOLUTION, PUZZLE.solve
    assert_equal 1, PUZZLE.solutions(limit: 2).size
  end

  def test_the_solution_is_solved_and_the_puzzle_is_not
    assert_predicate SOLUTION, :solved?
    refute_predicate PUZZLE, :solved?
    assert_equal 30, PUZZLE.filled
    assert_equal 81, SOLUTION.filled
  end

  def test_a_complete_grid_with_a_clash_is_not_solved
    grid = SOLUTION.with(0, 3) # row 0 and box 0 already hold a 3

    assert_predicate grid, :complete?
    refute_predicate grid, :solved?
  end

  def test_conflicts_name_every_cell_that_clashes
    assert_empty PUZZLE.conflicts
    assert_equal [0, 2], PUZZLE.with(2, 5).conflicts, "a 5 in row 0, which already has one at r0c0"
    assert_equal [9, 54, 55], PUZZLE.with(54, 6).conflicts, "a 6 at r6c0: column 0 has one at r1c0, row 6 at r6c1"
    assert_equal [10, 20], PUZZLE.with(10, 8).conflicts, "an 8 at r1c1: its box has one at r2c2"
  end

  def test_a_hint_fills_the_first_empty_cell_with_the_solution
    index = Sudoku.hint(PUZZLE, SOLUTION)

    assert_equal 2, index
    assert_equal "r0c2", Sudoku.key(index)
    assert_equal 4, SOLUTION[index]
  end

  def test_a_hint_corrects_a_wrong_cell_once_nothing_is_empty
    assert_equal 5, Sudoku.hint(SOLUTION.with(5, 1), SOLUTION)
  end

  def test_no_hint_for_a_solved_grid
    assert_nil Sudoku.hint(SOLUTION, SOLUTION)
  end

  def test_a_generated_puzzle_has_one_solution
    puzzle = Sudoku.generate(random: Random.new(7))

    assert_predicate puzzle.solution, :solved?
    assert_operator puzzle.givens.filled, :<=, 40
    assert_equal [puzzle.solution], puzzle.givens.solutions(limit: 2)
    assert_equal puzzle.solution, puzzle.givens.merge(puzzle.solution)
  end

  def test_a_map_round_trips_and_junk_is_an_empty_cell
    assert_equal PUZZLE, Sudoku::Grid.from_map(PUZZLE.to_map)
    assert_equal({ "r0c0" => 5, "r0c1" => 3 }, Sudoku::Grid.from_map(PUZZLE.to_map).to_map.first(2).to_h)

    grid = Sudoku::Grid.from_map("r0c0" => 5, "r0c1" => "x", "junk" => 3, "r8c8" => 10, "r8c7" => 0)

    assert_equal({ "r0c0" => 5 }, grid.to_map)
  end

  def test_merge_keeps_this_grids_digits_and_fills_the_rest
    entries = Sudoku::Grid.empty.with(0, 9).with(2, 4)

    merged = PUZZLE.merge(entries)

    assert_equal 5, merged[0], "a given wins"
    assert_equal 4, merged[2]
    assert_equal 31, merged.filled
  end
end
