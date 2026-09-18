# frozen_string_literal: true

require "json"
require "logger"
require "y/action_cable/client"

# A Ruby player that checks the grid. It joins a sudoku document over the
# cable's websocket the way a browser does, reads the grid once a burst of
# edits settles, and writes what it finds back into the document: the cells
# that clash, how far along the grid is, and a correct digit when someone
# asks for a hint. Players see its results the way they see each other's
# digits. Nothing else carries them. Its presence is a player's: a name, a
# color, and the cell it last touched.
#
#   SudokuPeer.new("demo:sudoku", url: "ws://127.0.0.1:3000/cable").run
#
# `peer:` takes a Y::ActionCable::Client already made. The checker runs in
# whatever calls `run`: a thread, a script, or a task under Falcon.
class SudokuPeer
  IDENTITY = { name: "Checker", color: "#7c3aed" }.freeze
  QUIET = 0.3      # seconds without further edits before the grid is checked
  KEEP_ALIVE = 10  # seconds between presence refreshes; pages forget a peer after 30
  GONE = 45        # seconds without a presence renewal before a player counts as gone
  EMPTY_FOR = 120  # seconds with nobody else here before the checker leaves
  MAX_STAY = 2 * 60 * 60

  # The document: five maps. The server writes the first, players the
  # second and last, the checker the middle two.
  GIVENS = "givens"       # cell => digit, the puzzle (see SudokuPuzzle)
  GRID = "grid"           # cell => digit, what players typed
  CONFLICTS = "conflicts" # cell => true for each cell that clashes
  PROGRESS = "progress"   # filled, conflicts, solved
  REQUESTS = "requests"   # hint => a number, from a player; deleted once served

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
    @state = "checking"
  end

  def run
    @peer.on_update { |_update, _doc, _changed| @changes << :changed }
    @peer.on_awareness { |frame| see(frame) }
    @peer.subscribe
    @logger.info("checker: joined #{@document_id}")
    check
    watch
  ensure
    @peer.send_awareness(@presence.clear_local_state)
    @peer.unsubscribe
  end

  # Leave, once any check under way is done.
  def stop = @changes << :stop

  private

  def doc = @peer.doc

  # Check after each burst of edits and say "still here" in the quiet.
  # Leave when told to, after a long stay, or once nobody else has been
  # here for a while.
  def watch
    started = now
    alone_since = nil
    while now - started < @stay
      case @changes.pop(timeout: KEEP_ALIVE)
      when :stop then return leave("told to")
      when nil then show(@state)
      else
        return leave("told to") if settle == :stop

        check
      end
      alone_since = people_here.empty? ? alone_since || now : nil
      return leave("nobody else here") if alone_since && now - alone_since > EMPTY_FOR
    end
    leave("stayed long enough")
  end

  def leave(why) = @logger.info("checker: leaving #{@document_id}, #{why}")

  # Let a burst of edits settle. Returns :stop if told to leave meanwhile.
  def settle
    while (event = @changes.pop(timeout: QUIET))
      return :stop if event == :stop
    end
  end

  # Read the grid and write back what it says. A hint goes in first, so the
  # conflicts and the count include it. Only what changed is written; a
  # check that finds nothing new sends nothing.
  def check
    givens = Sudoku::Grid.from_map(read(GIVENS))
    return if givens.filled.zero? # no puzzle yet; the server's update will come

    @solution ||= givens.solve
    grid = givens.merge(Sudoku::Grid.from_map(read(GRID)))
    hinted = Sudoku.hint(grid, @solution) if @solution && read(REQUESTS).key?("hint")
    grid = grid.with(hinted, @solution[hinted]) if hinted
    conflicts = grid.conflicts
    @peer.send_update(doc.diff { |d| write(d, grid, conflicts, hinted) })
    @state = status(grid, conflicts)
    show(@state, hinted || conflicts.first || @cell)
    @logger.info("checker: #{@state}")
  end

  def write(doc, grid, conflicts, hinted)
    doc.get_map(GRID)[Sudoku.key(hinted)] = grid[hinted] if hinted
    doc.get_map(REQUESTS).delete("hint")
    flags = doc.get_map(CONFLICTS)
    keys = conflicts.map { |i| Sudoku.key(i) }
    (flags.keys - keys).each { |key| flags.delete(key) }
    (keys - flags.keys).each { |key| flags[key] = true }
    progress = doc.get_map(PROGRESS)
    { "filled" => grid.filled, "conflicts" => conflicts.size, "solved" => grid.solved? }.each do |key, value|
      progress[key] = value unless progress.key?(key) && progress[key] == value
    end
  end

  def status(grid, conflicts)
    return "solved" if grid.solved?

    "#{grid.filled}/#{Sudoku::CELLS}#{", #{conflicts.size} clashing" if conflicts.any?}"
  end

  def read(name) = JSON.parse(doc.read_map(name) || "{}")

  # Presence in the shape the page gives every player, plus what the checker
  # found and a mark that says which player it is.
  def show(status, cell = @cell)
    @cell = cell
    state = { user: IDENTITY, checker: true, status: status, cell: cell && Sudoku.key(cell) }
    @peer.send_awareness(@presence.set_local_state(JSON.generate(state)))
  end

  # Everyone's presence, the checker's own echoed back among them, and when
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

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
