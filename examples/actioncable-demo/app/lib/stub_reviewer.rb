# frozen_string_literal: true

# A fixed review, so the demo works without a model.
class StubReviewer
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
end
