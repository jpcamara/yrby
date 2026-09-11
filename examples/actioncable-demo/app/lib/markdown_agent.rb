# frozen_string_literal: true

# The agent for a markdown document: the same collaborator as ReviewAgent,
# working on a Y.Text of markdown instead of Lexical blocks. It follows the
# document through a Y::ActionCable::Peer, writes its review at the end as
# the model streams, answers @agent lines, considers changes after a pause,
# takes tasks from its list and drafts sections where they point, yields
# while someone is in the section, and says what it is doing in its cursor
# label and the log. Sections are headings, blocks are paragraphs, tasks are
# "- [ ]" lines: markdown already has every structure it needs.
class MarkdownAgent
  include MarkdownPresence
  include MarkdownReactions
  include MarkdownWork
  include MarkdownEdits

  QUIET = 1.5
  EMPTY_FOR = 120
  MAX_STAY = 2 * 60 * 60
  ROOT = "markdown"
  REVIEW_TITLE = "Agent review"

  def initialize(document_id, reviewer: Reviewer.default, stay: MAX_STAY)
    @document_id = document_id
    @reviewer = reviewer
    @stay = stay
    @presence = Y::Awareness.new
    @changes = Queue.new
    @peer = Y::ActionCable::Peer.new(document_id, root: nil)
    @doc = @peer.doc
    @text = @doc.get_text(ROOT)
    @answered = []
    @paused = false
  end

  def run
    @seen = @text.to_s
    @peer.on_update { |_update, _doc, _changed| note_update }
    @peer.on_awareness { |frame| see_presence(frame) }
    @peer.subscribe
    (bytes = Store.current.replay(@document_id)) && @doc.apply_update(bytes)
    @seen = @text.to_s
    start_heartbeat
    write_review
    watch
  ensure
    stop_heartbeat
    @peer.unsubscribe
    Y::ActionCable.broadcast_awareness(@document_id, @presence.clear_local_state)
  end

  private

  def text = @text.to_s

  # Which lines an update touched: the first and last lines that differ from
  # what the agent last saw.
  def note_update
    now = text
    before = MarkdownDoc.lines(@seen)
    after = MarkdownDoc.lines(now)
    @seen = now
    first = (0...[before.length, after.length].min).find do |i|
      before[i] != after[i]
    end || [before.length, after.length].min
    tail = 0
    tail += 1 while tail < [before.length, after.length].min - first && before[-1 - tail] == after[-1 - tail]
    last = [after.length - 1 - tail, first].max
    @changes << [first, [last, after.length - 1].min]
  end

  def write_review
    present("reading the document", @text.length, sticky: true)
    ensure_trailing_newlines(2)
    flush.call(@doc.diff { @text.insert(@text.length, "## #{REVIEW_TITLE}\n\n") })
    @review = @text.relative_position(@text.length - 1)
    writer = MarkdownWriter.new(@doc, @text, flush: flush, at: @text.length)
    stream_into(writer, "writing a review") { |emit| @reviewer.stream(text, &emit) }
    ensure_trailing_newlines(1)
    present("wrote a review", @text.length)
  end

  def watch
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    empty_since = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < @stay
      if people_here.empty?
        empty_since ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - empty_since > EMPTY_FOR
      else
        empty_since = nil
      end
      changed = @changes.pop(timeout: work_pending? ? 0.04 : 2)
      unless changed
        work_step
        next
      end
      first, last = changed
      while (more = @changes.pop(timeout: QUIET))
        first = [first, more[0]].min
        last = [last, more[1]].max
      end
      react_to(first, last)
      @changes.clear
    end
  end

  def flush
    @flush ||= lambda do |update|
      next unless update

      Store.current.record(@document_id, update)
      Y::ActionCable.broadcast(@document_id, update)
      @seen = text # its own writes are not changes to react to
    end
  end
end
