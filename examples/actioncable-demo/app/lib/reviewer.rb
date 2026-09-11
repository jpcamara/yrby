# frozen_string_literal: true

module Reviewer
  # A real model when a Fireworks or Anthropic key is present, a stand-in
  # otherwise, so the demo runs either way. Never put a key in the repo:
  # export it in the shell.
  def self.default
    LlmReviewer.available? ? LlmReviewer.new : StubReviewer.new
  end

  # The first {...} in a reply, parsed; fences and prose around it ignored.
  def self.first_json(reply)
    text = reply.to_s.gsub(/```(?:json)?/, "")
    raise ArgumentError, "no JSON in reply" unless text.index("{") && text.rindex("}")

    JSON.parse(text[text.index("{")..text.rindex("}")])
  end

  # Model output for an edit plan: JSON, possibly wrapped in a code fence or
  # prose. The first {...} that parses wins.
  def self.parse_edits(reply)
    edits = first_json(reply)["edits"]
    raise ArgumentError, "no edits in reply" unless edits.is_a?(Array)

    edits
  end

  # Model output as plain text: lines starting with "- " or "* " are the
  # suggestions, everything else is the summary.
  def self.parse(reply)
    lines = reply.to_s.lines.map(&:strip).reject(&:empty?)
    bullets, prose = lines.partition { |l| l.start_with?("- ", "* ") }
    Review.new(summary: prose.join(" "),
               suggestions: bullets.map { |l| l[2..].strip })
  end
end
