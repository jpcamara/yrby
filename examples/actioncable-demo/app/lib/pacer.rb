# frozen_string_literal: true

# Evens out a model's stream. Tokens arrive in bursts, with silences while
# the model thinks, so writing each chunk as it lands makes text jump in
# clumps. The pacer buffers what arrives and lets it out a word or two at a
# time at a steady rate, speeding up when the buffer grows so it never lags
# the model by more than a moment. `feed` takes chunks; `drain` writes what
# is due now; `flush` writes the rest.
class Pacer
  # Characters per second, a hard cap: the model is always faster, and the
  # point is that people can watch the words arrive. AGENT_PACE overrides.
  RATE = ENV.fetch("AGENT_PACE", "60").to_f

  def initialize(rate: RATE, &write)
    @rate = rate
    @write = write
    @buffer = +""
    @last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @credit = 0.0
  end

  # Credit only accrues while there is something to write: after a silence,
  # the first chunk starts at the calm pace rather than paying out the wait.
  def feed(chunk)
    if @buffer.empty?
      @last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @credit = 0.0
    end
    @buffer << chunk.to_s
  end

  def pending? = !@buffer.empty?

  # Write the characters that have come due since the last drain, ending at
  # a word boundary when one is in reach.
  def drain
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @credit += (now - @last) * rate
    @last = now
    return if @buffer.empty? || @credit < 1

    take = [@credit.floor, @buffer.length].min
    boundary = @buffer.index(/\s/, take)
    take = boundary + 1 if boundary && boundary - take <= 6
    piece = @buffer.slice!(0, take)
    @credit -= piece.length
    @write.call(piece)
  end

  def flush
    return if @buffer.empty?

    piece = @buffer.dup
    @buffer.clear
    @write.call(piece)
  end

  private

  attr_reader :rate
end
