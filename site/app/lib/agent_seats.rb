# Which agents are in which rooms, and how many model calls the agents have
# made today. Both live in process memory, like Rooms: the site runs one
# process, and agents run in it (PageAgentJob on the async queue adapter).
# Each person in a room can bring one agent.
class AgentSeats
  class << self
    def current = @current ||= new
    attr_writer :current
  end

  def initialize(max: Limits::MAX_AGENTS, per_room: Limits::MAX_AGENTS_PER_ROOM,
                 calls_per_day: Limits::AGENT_CALLS_PER_DAY, clock: -> { Date.current })
    @max = max
    @per_room = per_room
    @calls_per_day = calls_per_day
    @clock = clock
    @seats = Set.new # [room, owner id]
    @calls = {}
    @lock = Mutex.new
  end

  # :ok and a seat for `owner`'s agent in `room`, :here when that agent is
  # already there, or :full when the room or the site has all the agents it
  # takes.
  def take(room, owner)
    @lock.synchronize do
      next :here if @seats.include?([room, owner])
      next :full if @seats.size >= @max || @seats.count { |r, _| r == room } >= @per_room

      @seats << [room, owner]
      :ok
    end
  end

  def release(room, owner) = @lock.synchronize { @seats.delete([room, owner]) }

  def count = @lock.synchronize { @seats.size }

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
