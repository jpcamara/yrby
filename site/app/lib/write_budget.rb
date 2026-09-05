# A process-wide ceiling on document writes per second, in front of SQLite.
#
# Every accepted document frame is a single-writer SQLite insert. The
# per-subscription and per-connection buckets each bound one client; none of
# them bounds the *sum* across all clients, and at the intended caps that sum
# can still outrun what one SQLite file absorbs before SQLITE_BUSY starts
# starving page requests. This is the aggregate shelf: over it, a document frame
# is shed (the client keeps the update queued and retries, the same shape as
# any other dropped frame), so a flood degrades write throughput instead of
# wedging the database under lock contention.
#
# One token bucket, process memory, mutex-guarded, the same one-node assumption
# as everything else here. Awareness never reaches it; only document writes are
# counted, checked after the frame is classified and before it is persisted.
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

  # True when the write is within budget. False sheds it; the caller drops the
  # frame and the client retries.
  def admit(now = monotonic)
    @mutex.synchronize do
      next true if @bucket.take(now)

      @shed += 1
      # Surface sustained shedding without logging every dropped frame.
      Rails.logger.warn("write-budget: shed #{@shed} document write(s) so far") if (@shed % 1000).zero?
      false
    end
  end

  def shed = @mutex.synchronize { @shed }

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
