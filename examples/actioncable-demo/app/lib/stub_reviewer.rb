# frozen_string_literal: true

# A fixed review, so the demo works without a model.
class StubReviewer
  # Seconds between words when streaming: about a model's pace by default.
  # Slow it down for a demo with AGENT_STUB_PACE=0.3.
  PACE = ENV.fetch("AGENT_STUB_PACE", "0.09").to_f

  def call(text)
    words = text.split.size
    blocks = text.lines.count
    Review.new(
      summary: "Read #{words} words across #{blocks} blocks. The checklist reads clearly; " \
               "every step has an owner implied by context.",
      suggestions: ["Name who signs off before the report is published.",
                    "Add a rollback step after the canary check."]
    )
  end

  # The same review, a word at a time, the way a model streams.
  def stream(text)
    review = call(text)
    lines = [review.summary] + review.suggestions.map { |s| "- #{s}" }
    lines.each do |line|
      line.split(/(?<= )/).each do |word|
        yield word
        sleep PACE
      end
      yield "\n"
    end
  end
end
