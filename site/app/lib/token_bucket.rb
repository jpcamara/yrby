# A token bucket, one per subscription, in front of the channel's receive path.
#
# yrby validates every frame before anything touches it, so a malformed or
# oversized frame is already dropped. This is about volume: a well-formed client
# sending ten thousand valid updates a second is still a denial of service, and
# validity says nothing about rate.
#
# `capacity` tokens accumulate at `refill_per_second`, one token per frame. A
# client under the rate never notices. A client over it has frames dropped,
# which for a document update means the client keeps it queued and retries —
# the same shape as any other dropped frame in the protocol.
#
# The bucket does not live in the channel object. Sockets terminate in
# anycable-go and every command arrives as a fresh RPC call with a fresh channel
# instance, so the bucket travels as channel state: `dump` is three numbers and
# `load` rebuilds from them. Small enough to serialize on every message, and it
# needs no cleanup because it dies with the subscription.
class TokenBucket
  attr_reader :drops

  def self.load(dumped, capacity:, refill_per_second:)
    bucket = new(capacity: capacity, refill_per_second: refill_per_second)
    dumped ? bucket.restore(dumped) : bucket
  end

  def initialize(capacity:, refill_per_second:, now: monotonic)
    @capacity = capacity.to_f
    @refill = refill_per_second.to_f
    @tokens = @capacity
    @updated_at = now
    @drops = 0
  end

  # True when the frame is allowed. False when the bucket is empty, and the
  # caller should drop the frame.
  def take(now = monotonic)
    @tokens = [@capacity, @tokens + ((now - @updated_at) * @refill)].min
    @updated_at = now
    if @tokens < 1
      @drops += 1
      return false
    end

    @tokens -= 1
    true
  end

  def dump = [@tokens, @updated_at, @drops]

  def restore(dumped)
    tokens, updated_at, drops = dumped
    @tokens = tokens.to_f
    @updated_at = updated_at.to_f
    @drops = drops.to_i
    self
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
