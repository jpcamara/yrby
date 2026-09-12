# frozen_string_literal: true

# The agent's arrival and its review: a hello that says what happens first
# and how to talk to it, then the review typed at the end as a stream the
# loop steps, so the first task can start alongside it.
module AgentReview
  INTRO = "I'll review the document and work through any list under a heading that names me. " \
          "Talk to me with a line starting @agent, or use the buttons."

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
    writer = open_review
    @review = StreamJob.new(writer: writer, label: "the review", on_finish: -> { review_written(writer) }) do |emit|
      @reviewer.stream(text, &emit)
    end
  end

  # A document invited more than once keeps one review section: a new review
  # goes at the end of the existing one.
  def open_review
    heading = heading_block("Agent review")
    @made_review_heading = heading.nil?
    if heading
      @review_heading = heading.anchor
      last = root.xml_text(section_end(doc.block_at(heading.anchor)))
      StreamingWriter.new(doc, flush: flush, after: last.anchor)
    else
      flush.call(doc.diff { Y::Lexical.append_heading(doc, "Agent review", tag: "h2") })
      @review_heading = last_block.anchor
      StreamingWriter.new(doc, flush: flush, after: @review_heading)
    end
  end

  def review_written(writer)
    forget_thinking("the review")
    @list = writer.list
    @review_list = @list&.anchor
    at = writer.block || last_block
    if @review.failed?
      @made_review_heading && (i = doc.block_at(@review_heading)) && flush.call(doc.diff { root.delete_xml_text(i) })
      report_failure("the review", @review.error, "ask me again with @agent review")
    else
      present("wrote a review", end_of(at), end_of(at))
    end
    announce_next
  end

  # Let the review out a little. While a draft runs too, the caret stays
  # with the draft and one status names both, so the ledger and the bar do
  # not flicker between the two.
  def step_review
    return unless reviewing?

    @review.step
    return if @review.finished? || drafting? || !@review.writer.block

    present_caret(working_label, start_of_written(@review.writer) || end_of(@review.writer.block),
                  end_of(@review.writer.block), sticky: true)
  end

  def reviewing? = @review && !@review.finished?
  def busy? = reviewing? || work_pending?

  # One label for everything in flight.
  def working_label
    titles = drafts.map(&:title).join(" and ")
    [reviewing? ? "writing a review" : nil, drafting? ? "drafting #{titles}" : nil].compact.join(" and ")
  end

  # What the loop does between changes: let the streams out, do own work,
  # and notice when the room has been empty for a while.
  def idle_tick
    step_review
    work_step
  end
end
