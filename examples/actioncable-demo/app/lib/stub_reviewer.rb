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

  # A fixed plan: split the task sentence into a checklist and tighten the intro.
  def edits(_instruction, blocks)
    tasks = blocks.index { |b| b.start_with?("Collect") } || (blocks.size - 1)
    intro = blocks.index { |b| b.start_with?("This document") }
    plan = [{ "op" => "heading", "block" => 0, "level" => 1 },
            { "op" => "replace", "block" => tasks, "text" => "Launch checklist, one owner per item:" },
            { "op" => "insert_after", "block" => tasks,
              "text" => "- Collect deployment metrics (owner: SRE)\n" \
                        "- Verify the canary rollout (owner: release lead)\n" \
                        "- Confirm on-call coverage (owner: on-call manager)\n" \
                        "- Sign off and publish the report (owner: PM)" }]
    if intro
      plan << { "op" => "replace", "block" => intro,
                "text" => "Our go-live checklist, edited together with a Ruby agent." }
    end
    plan
  end

  # Between requests: a task line with no owner gets one asked for; a
  # question in the text gets a one-line answer; otherwise nothing.
  def consider(changed_blocks, occupied, blocks)
    edits = []
    changed_blocks.each do |i|
      next if occupied.include?(i)

      line = blocks[i].to_s
      if line.end_with?("?") && !line.start_with?("@agent")
        edits << { "op" => "insert_after", "block" => i,
                   "text" => "Suggestion: the release manager owns that; add it to the checklist." }
      elsif line.match?(/\A(collect|verify|confirm|run|check|deploy|sign off)\b/i) && !line.match?(/owner/i)
        edits << { "op" => "replace", "block" => i, "text" => "#{line.sub(/\.\z/, "")} — owner: ?" }
      end
    end
    LlmReviewer::Consideration.new(note: edits.empty? ? "nothing to add" : "added to what you wrote", edits: edits)
  end
end
