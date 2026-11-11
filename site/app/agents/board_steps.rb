require "json"

# How a board agent makes each change people watch: what it says it's doing,
# what it selects, its cursor, one edit per change, a pause, and what the
# ask's Undo needs. BoardAgent includes it, for the ask it's answering (@ask).
module BoardSteps
  MAX_CHANGES = 150 # per ask

  private

  # Says what the agent is doing on its ask's card, and selects the items it's
  # about to change, so people see them all highlighted in its color.
  def doing(activity, ids = [])
    self.presence = presence.merge("selection" => ids.first(BoardWrites::MAX_PER_CALL))
    edit { write(@ask, "activity" => activity) } if working?(@ask)
  end

  # Adds an item it just made to its selection.
  def select_too(key)
    self.presence = presence.merge("selection" => [*presence["selection"], key].last(BoardWrites::MAX_PER_CALL))
  end

  def count(number, noun) = "#{number} #{noun}#{"s" unless number == 1}"

  # One change: the cursor goes to `at`, the change happens in one edit, and
  # the agent waits so people see it. Raises Stopped once people stopped or
  # undid the ask.
  def step(at)
    @acted = true
    raise AgentModel::Stopped unless working?(@ask)
    if @changes >= MAX_CHANGES
      raise BoardSpec::Invalid, "this ask has made #{MAX_CHANGES} changes, the most it can; stop and reply"
    end

    point(at, @ask)
    edit do
      yield
      ask = asks.get_map(@ask)
      ask["drawn"] = ask["drawn"].to_i + 1
    end
    @changes += 1
    sleep @pace
  end

  # Around one change to `key`: keeps the item as it was before this ask
  # first touched it, and as the ask left it, for Undo. An item the ask added
  # needs neither; Undo removes it.
  def keeping(key)
    ask = asks.get_map(@ask)
    item = board.item(key)
    ask.get_map("before")[key] ||= JSON.generate(item) if item && item["ask"] != @ask
    yield
    return unless ask.get_map("before")[key]

    now = board.item(key)
    ask.get_map("after")[key] = now ? JSON.generate(now) : ""
  end
end
