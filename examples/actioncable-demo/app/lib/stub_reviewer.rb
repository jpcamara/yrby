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

  # A canned answer, streamed a word at a time.
  def answer(question, text)
    words = text.split.size
    reply = "You asked: #{question.sub(/\A@agent\s*/i, "").strip} The document has #{words} words. " \
            "What I would add: **a named owner** for sign-off and a `rollback` step after the canary check.\n" \
            "- Owner for sign-off\n- Rollback after canary\n"
    reply.split(/(?<= )|(?<=\n)/).each do |piece|
      yield piece
      sleep PACE
    end
  end
end
