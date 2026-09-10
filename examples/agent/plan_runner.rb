# frozen_string_literal: true

# An agent that runs a plan other people can edit while it runs.
#
# The plan is a shared document with one step per line in its "content" text.
# Progress goes to a second shared document, so a browser can watch it. The
# runner keeps nothing in memory between steps. Before it executes a step it
# reloads the plan from storage, which is where every browser edit lands before
# it is acknowledged. So an edit made while an earlier step was running is what
# gets executed. If the step it is running changes underneath it, it runs that
# step again with the new text, once.
#
# The executor is anything that responds to call(text) and returns a result.
# An LLM call, a shell command, or a stub for a test all fit.
class PlanRunner
  Step = Data.define(:index, :text)

  def initialize(plan:, log:, executor:, redo_limit: 1)
    @plan = plan
    @log = log
    @executor = executor
    @redo_limit = redo_limit
  end

  def run
    index = 0
    while (step = current_step(index))
      execute(step)
      index += 1
    end
    say "Plan complete."
  end

  private

  # Re-read from storage on every call. An unwritten plan reads as nil. Blank
  # lines are not steps.
  def steps
    (@plan.doc.read_text("content") || "").lines.map(&:strip).reject(&:empty?)
  end

  def current_step(index)
    text = steps[index]
    text && Step.new(index: index, text: text)
  end

  def execute(step)
    redos = 0
    loop do
      say "Running: #{step.text}"
      result = @executor.call(step.text)
      latest = current_step(step.index)
      if latest && latest.text != step.text && redos < @redo_limit
        say "Changed while running, doing it again: #{latest.text}"
        step = latest
        redos += 1
        next
      end
      say "Done: #{step.text} -> #{result}"
      return
    end
  end

  def say(line)
    @log.edit { |doc| doc.get_text("content").push("#{line}\n") }
  end
end
