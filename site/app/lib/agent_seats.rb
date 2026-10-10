# Which rooms have an agent, and how many model calls the agents have made
# today. Both live in process memory, like Rooms: the site runs one process,
# and agents run in it (ReviewAgentJob on the async queue adapter).
class AgentSeats
  class << self
    def current = @current ||= new
    attr_writer :current
  end

  def initialize(max: Limits::MAX_AGENTS, calls_per_day: Limits::AGENT_CALLS_PER_DAY, clock: -> { Date.current })
    @max = max
    @calls_per_day = calls_per_day
    @clock = clock
    @rooms = Set.new
    @calls = {}
    @lock = Mutex.new
  end

  # :ok and a seat for `room`, :here when the room already has an agent, or
  # :full when MAX_AGENTS are running.
  def take(room)
    @lock.synchronize do
      next :here if @rooms.include?(room)
      next :full if @rooms.size >= @max

      @rooms << room
      :ok
    end
  end

  def release(room) = @lock.synchronize { @rooms.delete(room) }

  def count = @lock.synchronize { @rooms.size }

  # Counts one model call. False when today's budget is spent.
  def spend_call
    @lock.synchronize do
      today = @clock.call
      @calls = { today => @calls.fetch(today, 0) }
      next false if @calls[today] >= @calls_per_day

      @calls[today] += 1
      true
    end
  end
end
