# frozen_string_literal: true

# MarkdownAgent's arrival and review, as AgentReview is for the Lexxy agent:
# a hello, then the review typed at the end as a stream the loop steps.
module MarkdownReview
  private

  def introduce
    present("hello", @text.length, sticky: true, detail: AgentReview::INTRO)
    sleep 1.5
  end

  def start_review
    present("reading the document", @text.length, sticky: true)
    ensure_trailing_newlines(2)
    flush.call(@doc.diff { @text.insert(@text.length, "## #{MarkdownAgent::REVIEW_TITLE}\n\n") })
    @review = @text.relative_position(@text.length - 1)
    writer = MarkdownWriter.new(@doc, @text, flush: flush, at: @text.length)
    @review_job = StreamJob.new(writer: writer, on_finish: -> { review_written(writer) }) do |emit|
      @reviewer.stream(text, &emit)
    end
  end

  def review_written(writer)
    ensure_trailing_newlines(1) if writer.index >= @text.length
    present("wrote a review", writer.index)
    announce_next
  end

  def step_review
    return unless reviewing?

    @review_job.step
    return if drafting?

    writer = @review_job.writer
    present(working_label, writer.start_index || writer.index, writer.index, sticky: true)
  end

  def reviewing? = @review_job && !@review_job.finished?
  def drafting? = @draft && !@draft.finished?
  def busy? = reviewing? || work_pending?

  def working_label
    [reviewing? ? "writing a review" : nil, drafting? ? "drafting #{@section_title}" : nil].compact.join(" and ")
  end

  def idle_tick
    step_review
    work_step
  end
end
