# Limits document writes per second for the whole process, before they reach
# SQLite.
#
# Every accepted document frame is an insert into SQLite, which allows one
# writer at a time. The per-connection buckets each limit one client, but
# nothing else limits the total across all clients. At the configured caps
# that total can still be more than one SQLite file can handle, and then
# SQLITE_BUSY starts blocking page requests. Over this budget, the server drops
# document frames. The client keeps the update queued and retries, the same as
# for any other dropped frame. A flood slows down writes without locking up
# the database.
#
# It's one token bucket in process memory behind a mutex, and like the rest of
# these limits it assumes one server. Awareness frames don't count. The channel
# checks this after it classifies a frame as a document write and before it's
# saved.
class WriteBudget
  class << self
    attr_writer :current

    def current = @current ||= new
  end

  def initialize(capacity: Limits::DOCUMENT_WRITE_BURST,
                 refill_per_second: Limits::DOCUMENT_WRITES_PER_SECOND,
                 now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @bucket = TokenBucket.new(capacity: capacity, refill_per_second: refill_per_second, now: now)
    @mutex = Mutex.new
    @shed = 0
  end

  # Returns true when the write fits the budget. Returns false when it doesn't,
  # and the caller drops the frame so the client retries.
  def admit(now = monotonic)
    @mutex.synchronize do
      next true if @bucket.take(now)

      @shed += 1
      # Log every 1000th dropped write so steady dropping shows up in the logs
      # without a line per frame.
      Rails.logger.warn("write-budget: dropped #{@shed} document write(s) so far") if (@shed % 1000).zero?
      false
    end
  end

  def shed = @mutex.synchronize { @shed }

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
