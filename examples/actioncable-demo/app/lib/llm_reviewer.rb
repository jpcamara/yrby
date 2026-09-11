# frozen_string_literal: true

# A review from a model through ruby_llm. Fireworks AI (OpenAI-compatible,
# FIREWORKS_API_KEY) or Anthropic (ANTHROPIC_API_KEY), whichever key is set;
# AGENT_MODEL overrides the model. Any failure falls back to the stub, so a
# bad key or a network blip never leaves the document without a review.
class LlmReviewer
  FIREWORKS_BASE = "https://api.fireworks.ai/inference/v1"
  FIREWORKS_MODEL = "accounts/fireworks/models/glm-5p3-flash"
  ANTHROPIC_MODEL = "claude-sonnet-5"

  PROMPT = <<~PROMPT
    You are reviewing a short working document that a team is editing together.
    Reply in plain text with no markdown headings: first one short paragraph
    summarizing what the document is and how it reads, then two or three
    concrete suggestions, each on its own line starting with "- ".

    Document:
    %s
  PROMPT

  QUESTION_PROMPT = <<~PROMPT
    You are a collaborator in a short working document that a team is editing
    together. Someone in the document asked you a question, marked with @agent.
    Answer it in plain text with no markdown headings: a short paragraph, then
    if useful two or three concrete points, each on its own line starting with "- ".

    Question:
    %s

    Document:
    %s
  PROMPT

  EDIT_PROMPT = <<~PROMPT
    You are editing a short working document that a team shares. The document
    is a list of numbered blocks. Apply this instruction: %s

    Reply with JSON only, no prose, no code fences: {"edits":[...]} where each
    edit is one of:
    {"op":"replace","block":N,"text":"new text for that block"}
    {"op":"insert_after","block":N,"text":"text for a new block after N"}
    {"op":"delete","block":N}
    {"op":"heading","block":N,"level":2}
    In insert_after text, start a line with "- " for a bullet or "1. " for a
    numbered item; several lines make several blocks. Refer to blocks by
    number. Keep edits minimal and concrete. At most 12 edits.

    Document:
    %s
  PROMPT

  # An edit plan for `instruction` over `blocks` (the document's top-level
  # blocks, in order). Falls back to the stub's plan.
  # `only:` is a range of block numbers the request applies to; the plan is
  # asked for and then held to it.
  def edits(instruction, blocks, only: nil)
    numbered = blocks.each_with_index.map { |b, i| "[#{i}] #{b}" }.join("\n")
    if only
      which = only.first == only.last ? "block #{only.first}" : "blocks #{only.first} to #{only.last}"
      instruction = "#{instruction} Apply this only to #{which}; do not change any other block."
    end
    plan = Reviewer.parse_edits(ask(format(EDIT_PROMPT, instruction.inspect, numbered)))
    plan = plan.select { |e| only.cover?(e["block"]) } if only
    remember("Edited the document on request (#{instruction}): " + plan.map { |e|
      "#{e["op"]} block #{e["block"]}"
    }.join(", "))
    plan
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.edits(instruction, blocks, only: only)
  end

  def self.available?
    !ENV["FIREWORKS_API_KEY"].to_s.empty? || !ENV["ANTHROPIC_API_KEY"].to_s.empty?
  end

  def call(text)
    review = Reviewer.parse(ask(format(PROMPT, text)))
    remember("Reviewed the document: #{review.summary}")
    review
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.call(text)
  end

  # Chunks as the model produces them. If the model fails before the first
  # chunk, the stub's stream takes over; a failure mid-stream ends it, since
  # a fixed review after real words would read as nonsense.
  def stream(text, &block)
    started = false
    said = +""
    streamed(format(PROMPT, text)) do |chunk|
      started = true
      said << chunk
      block.call(chunk)
    end
    remember("Reviewed the document and wrote: #{said}")
  rescue StandardError => e
    raise if started

    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.stream(text, &block)
  end

  # An answer, streamed, with the same fallback rule.
  DRAFT_PROMPT = <<~PROMPT
    Draft the section "%s" for the document below. The heading is already in
    place; write only the body: two to four short paragraphs, or a bulleted
    list where the content is a list. Be specific to this document, do not
    repeat what it already says, and leave a clear "to confirm" line for any
    fact you do not have. Markdown for lists and emphasis is fine; no headings.

    Document:
    %s
  PROMPT

  def draft(task, text, &block)
    started = false
    said = +""
    streamed(format(DRAFT_PROMPT, task, text)) do |chunk|
      started = true
      said << chunk
      block.call(chunk)
    end
    remember("Drafted the section \"#{task}\": #{said}")
  rescue StandardError => e
    raise if started

    Rails.logger.warn("LlmReviewer draft fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.draft(task, text, &block)
  end

  def answer(question, text, &block)
    started = false
    said = +""
    streamed(format(QUESTION_PROMPT, question, text)) do |chunk|
      started = true
      said << chunk
      block.call(chunk)
    end
    remember("Answered \"#{question}\": #{said}")
  rescue StandardError => e
    raise if started

    Rails.logger.warn("LlmReviewer fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.answer(question, text, &block)
  end

  INSTRUCTIONS = <<~TXT
    You are a collaborator in a short working document that a team edits
    together in real time. You review it, answer questions addressed to
    @agent, edit it on request, and, between requests, notice what people
    write and contribute only when it clearly helps. Keep contributions
    small, concrete, and additive. Never restate the document. Remember what
    you have already said and done in this document.
  TXT

  CONSIDER_PROMPT = <<~PROMPT
    People just changed these blocks (by number):
    %s

    Do not touch blocks: %s. Someone is writing there, or they are your own
    task list and the sections you drafted.

    Decide whether a small contribution is clearly helpful right now: an
    owner or date a task is missing, a question in the text you can answer,
    a TODO you can draft in a line or two, a plain error. If not, do nothing.
    Suggestions under the "Agent review" heading are your own earlier
    review, not requests from the team; do not act on them here.

    Reply with JSON only: {"note":"one short line on what you did or why not","edits":[...]}
    where edits is empty or holds at most 3 of:
    {"op":"replace","block":N,"text":"..."} {"op":"insert_after","block":N,"text":"..."} {"op":"delete","block":N}

    Document:
    %s
  PROMPT

  Consideration = Data.define(:note, :edits)

  MEMORY_LIMIT = 8

  def initialize
    @memory = []
  end

  # What the agent has done in this document so far, for the next prompt. A
  # reasoning model's reply history is large and some providers reject it
  # when sent back, so the agent carries its own short account instead.
  def remember(line)
    @memory << line.to_s.gsub(/\s+/, " ").strip[0, 240]
    @memory.shift while @memory.size > MEMORY_LIMIT
  end

  def memory_prompt
    return "" if @memory.empty?

    lines = @memory.map { |m| "- #{m}" }.join("\n")
    "What you have already done in this document, oldest first:\n#{lines}\n\n"
  end

  # Between requests: given what changed and where people are, a small plan
  # or nothing. Falls back to the stub's judgment.
  def consider(changed_blocks, occupied, blocks)
    numbered = blocks.each_with_index.map { |b, i| "[#{i}] #{b}" }.join("\n")
    changed = changed_blocks.map { |i| "[#{i}] #{blocks[i]}" }.join("\n")
    reply = ask(format(CONSIDER_PROMPT, changed, occupied.empty? ? "none" : occupied.join(", "), numbered))
    json = Reviewer.first_json(reply)
    result = Consideration.new(note: json["note"].to_s, edits: Array(json["edits"]))
    did = result.edits.empty? ? "Saw a change and left it alone" : "Contributed after a change"
    remember("#{did}: #{result.note}")
    result
  rescue StandardError => e
    Rails.logger.warn("LlmReviewer consider fell back to the stub: #{e.class}: #{e.message}")
    StubReviewer.new.consider(changed_blocks, occupied, blocks)
  end

  private

  # Stream a prompt, skipping the chunks a reasoning model sends with no text.
  def streamed(prompt)
    chat.ask(memory_prompt + prompt) do |chunk|
      content = chunk.content.to_s
      yield content unless content.empty?
    end
    nil
  end

  def ask(prompt)
    chat.ask(memory_prompt + prompt).content.to_s
  end

  # A fresh chat per call, with the standing instructions. The reviewer's own
  # memory goes in the prompt, so no reply history is sent back.
  def chat
    require "ruby_llm"
    if ENV["FIREWORKS_API_KEY"].to_s.empty?
      RubyLLM.configure do |c|
        c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
        c.request_timeout = 90
      end
      RubyLLM.chat(model: ENV.fetch("AGENT_MODEL", ANTHROPIC_MODEL), provider: :anthropic, assume_model_exists: true)
    else
      RubyLLM.configure do |c|
        c.openai_api_key = ENV.fetch("FIREWORKS_API_KEY")
        c.openai_api_base = FIREWORKS_BASE
        c.request_timeout = 90
      end
      RubyLLM.chat(model: ENV.fetch("AGENT_MODEL", FIREWORKS_MODEL), provider: :openai, assume_model_exists: true)
    end.with_instructions(INSTRUCTIONS)
  end
end
