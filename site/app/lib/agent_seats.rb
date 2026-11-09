# Which agents are in which rooms, and how many model calls the agents have
# made today. Both are rows in the database, so the web server and every job
# process (bin/jobs) count the same seats and the same budget. Each person in
# a room can bring one agent.
class AgentSeats
  class Seat < ApplicationRecord
    self.table_name = "agent_seats"
  end

  class CallDay < ApplicationRecord
    self.table_name = "agent_call_days"
  end

  # No agent stays longer than AGENT_MAX_STAY, so a seat older than that,
  # plus a minute to get going, belongs to an agent whose process died
  # before its job could give the seat back.
  STALE = Limits::AGENT_MAX_STAY + 60 # seconds

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
  end

  # :ok and a seat for `owner`'s agent in `room`, :here when that agent is
  # already there, or :full when the room or the site has all the agents it
  # takes. Rails begins SQLite transactions IMMEDIATE, so the transaction
  # holds the write lock from its first statement, and two processes can't
  # both count the last free seat.
  def take(room, owner)
    Seat.transaction do
      Seat.where(created_at: ...STALE.seconds.ago).delete_all
      next :here if Seat.exists?(room:, owner:)
      next :full if Seat.count >= @max || Seat.where(room:).count >= @per_room

      Seat.create!(room:, owner:)
      :ok
    end
  end

  def release(room, owner) = Seat.where(room:, owner:).delete_all

  def count = Seat.count

  # Counts one model call. False when today's budget is spent.
  def spend_call # rubocop:disable Naming/PredicateMethod -- it spends, and says whether it could
    today = @clock.call
    CallDay.where(day: ...today).delete_all
    CallDay.insert_all([{ day: today, calls: 0 }], unique_by: :day)
    CallDay.where(day: today, calls: ...@calls_per_day).update_all("calls = calls + 1") == 1
  end
end
