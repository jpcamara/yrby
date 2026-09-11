# frozen_string_literal: true

# A model stream written into the document at a steady pace, stepped by the
# agent's loop so several can run at once and the loop keeps reacting in
# between. `produce` runs in a thread and calls `emit` with each chunk; the
# loop calls `step` to let a little out. `on_finish` runs once everything
# streamed has been written.
class StreamJob
  def initialize(writer:, on_finish: nil, &produce)
    @writer = writer
    @on_finish = on_finish
    @queue = Queue.new
    @pacer = Pacer.new { |piece| writer.feed(piece) }
    @done = false
    @finished = false
    @thread = Thread.new do
      produce.call(->(chunk) { @queue << chunk })
    rescue StandardError => e
      Rails.logger.warn("agent stream failed: #{e.class}: #{e.message}")
    ensure
      @queue << :done
    end
  end

  attr_reader :writer

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
    @writer.finish
    @on_finish&.call
  end
end
