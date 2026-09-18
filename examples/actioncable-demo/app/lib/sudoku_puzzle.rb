# frozen_string_literal: true

# The puzzle of a sudoku document: its givens, made on the server the first
# time the page is opened and recorded in the document, so every player and
# the checker see the same one. The page does not let anyone change them.
module SudokuPuzzle
  GIVENS = "givens"
  LOCK = Mutex.new # two first opens in this process make one puzzle, not two

  module_function

  # Record a puzzle into the document unless it has one. Anyone already
  # subscribed gets it the way they get an edit.
  def ensure(document_id)
    LOCK.synchronize do
      doc = Y::Doc.new
      (bytes = Store.current.replay(document_id)) && doc.apply_update(bytes)
      return if JSON.parse(doc.read_map(GIVENS) || "{}").any?

      puzzle = Sudoku.generate
      update = doc.diff { |d| puzzle.givens.to_map.each { |key, digit| d.get_map(GIVENS)[key] = digit } }
      Store.current.record(document_id, update)
      Y::ActionCable.broadcast(document_id, update)
    end
  end
end
