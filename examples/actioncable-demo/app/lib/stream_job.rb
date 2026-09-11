# frozen_string_literal: true

# A model stream written into the document at a steady pace, stepped by the
# agent's loop so several can run at once and the loop keeps reacting in
# between. `produce` runs in a thread and calls `emit` with each chunk; the
# loop calls `step` to let a little out. `on_finish` runs once everything
# streamed has been written.
class StreamJob
  RUNNING = Set.new
  RUNNING_LOCK = Mutex.new

  # Names of the streams running right now, for the presence to file
  # reasoning under.
  def self.running?(label) = RUNNING_LOCK.synchronize { RUNNING.include?(label) }

  # `label:` names the stream in the ledger ("the review", a section title).
  def initialize(writer:, on_finish: nil, pace: Pacer::RATE, label: nil, &produce)
    @writer = writer
    @on_finish = on_finish
    @label = label
    RUNNING_LOCK.synchronize { RUNNING << label } if label
    @queue = Queue.new
    @pacer = Pacer.new(rate: pace) { |piece| writer.feed(piece) }
    @done = false
    @finished = false
    @error = nil
    @produced = false
    @thread = Thread.new do
      Thread.current[:agent_purpose] = label
      produce.call(lambda { |chunk|
        @produced = true
        @queue << chunk
      })
    rescue StandardError => e
      Rails.logger.warn("agent stream failed: #{e.class}: #{e.message}")
      @error = e
    ensure
      @queue << :done
    end
  end

  attr_reader :writer, :error, :label

  # Nothing came out of the model at all.
  def failed? = !@error.nil? && !@produced

  def finished? = @finished

  # Pull what the model has produced, write a little of it, and finish when
  # everything is out. Returns :more while there is more to do, else :done.
  def step
    return :done if @finished

    loop do
      chunk = @queue.pop(true)
      chunk == :done ? @done = true : @pacer.feed(chunk)
    rescue ThreadError
      break
    end
    @pacer.drain if @pacer.pending?
    return :more unless @done && !@pacer.pending?

    finish
    :done
  end

  def pending? = @pacer.pending?

  def stop
    @thread.kill
    @pacer.flush
    finish
  end

  private

  def finish
    return if @finished

    @finished = true
    RUNNING_LOCK.synchronize { RUNNING.delete(@label) } if @label
    @writer.finish
    @on_finish&.call
  end
end
