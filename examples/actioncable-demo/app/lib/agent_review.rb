# frozen_string_literal: true

# The agent's arrival and its review: a hello that says what happens first
# and how to talk to it, then the review typed at the end as a stream the
# loop steps, so the first task can start alongside it.
module AgentReview
  INTRO = "I'll review the document, and work through any list under a heading that names me at the " \
          "same time. Ask me with a line starting @agent, hand me a task with @agent take ..., or use " \
          "the buttons."

  private

  # Say hello where people can see it: what happens first, and how to talk
  # to the agent.
  def introduce
    @answered = []
    @undos = []
    present("hello", end_of(last_block), end_of(last_block), sticky: true, detail: INTRO)
    sleep 1.5
  end

  # The review, typed into the document as the reviewer produces it, as a
  # stream the watch loop steps so the first task can start alongside it.
  def start_review
    present("reading the document", end_of(last_block), end_of(last_block), sticky: true)
    flush.call(doc.diff { Y::Lexical.append_heading(doc, "Agent review", tag: "h2") })
    writer = StreamingWriter.new(doc, flush: flush)
    @review = StreamJob.new(writer: writer, on_finish: -> { review_written(writer) }) do |emit|
      @reviewer.stream(text, &emit)
    end
  end

  def review_written(writer)
    @list = writer.list
    @review_list = @list&.anchor
    at = writer.block || last_block
    present("wrote a review", end_of(at), end_of(at))
    announce_next
  end

  # Let the review out a little. While a draft runs too, the caret stays
  # with the draft and one status names both, so the ledger and the bar do
  # not flicker between the two.
  def step_review
    return unless reviewing?

    @review.step
    return if drafting? || !@review.writer.block

    present(working_label, start_of_written(@review.writer) || end_of(@review.writer.block),
            end_of(@review.writer.block), sticky: true)
  end

  def reviewing? = @review && !@review.finished?
  def drafting? = @draft && !@draft.finished?
  def busy? = reviewing? || work_pending?

  # One label for everything in flight.
  def working_label
    [reviewing? ? "writing a review" : nil, drafting? ? "drafting #{@section_title}" : nil].compact.join(" and ")
  end

  # What the loop does between changes: let the streams out, do own work,
  # and notice when the room has been empty for a while.
  def idle_tick
    step_review
    work_step
  end
end
