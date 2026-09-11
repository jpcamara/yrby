# frozen_string_literal: true

# A Ruby agent that joins a document as a live collaborator. It follows the
# document through a Y::ActionCable::Peer, one live doc for the whole run,
# so it sees people's edits as they happen. It types its review into the
# document as the reviewer produces it, then stays: it considers changes
# once the typing pauses, answers lines addressed to it, and works through
# its own list. What it is doing is always in its cursor label and in the
# log under the editor, and its caret only goes where it is working. It
# leaves when nobody else has been here for a while. The presence is
# Y::Awareness; the writing is Y::Lexical over Y::XmlText, recorded and
# broadcast like any other edit.
class ReviewAgent
  include AgentPresence
  include AgentReactions
  include AgentWork

  QUIET = 1.5 # seconds without further edits before the agent notes a change
  KEEP_ALIVE = 15 # presence expires in editors after 30s of silence; refresh before that

  EMPTY_FOR = 120 # seconds with nobody else here before the agent leaves
  MAX_STAY = 2 * 60 * 60

  def initialize(document_id, reviewer: Reviewer.default, stay: MAX_STAY)
    @document_id = document_id
    @reviewer = reviewer
    @stay = stay
    @presence = Y::Awareness.new
    @changes = Queue.new
    @peer = Y::ActionCable::Peer.new(document_id)
    @list = nil
    @recent_changes = []
  end

  def run
    @peer.on_update { |_update, _doc, changed| @changes << changed }
    @peer.on_awareness { |frame| see_presence(frame) }
    @peer.subscribe
    (bytes = Store.current.replay(@document_id)) && doc.apply_update(bytes)
    start_heartbeat
    write_review
    watch
  ensure
    stop_heartbeat
    @peer.unsubscribe
    Y::ActionCable.broadcast_awareness(@document_id, @presence.clear_local_state)
  end

  private

  def doc = @peer.doc
  def root = doc.get_xml_text("root")
  def text = doc.read_xml("root").to_s

  # The review, typed into the document as the reviewer produces it. Every
  # insert is a diff the open editors apply, so people watch the agent write.
  def write_review
    present("reading the document", end_of(last_block), end_of(last_block), sticky: true)
    flush.call(doc.diff { Y::Lexical.append_heading(doc, "Agent review", tag: "h2") })
    writer = StreamingWriter.new(doc, flush: flush)
    stream_into(writer, "writing a review") { |emit| @reviewer.stream(text, &emit) }
    @list = writer.list
    @review_list = @list&.anchor
    @answered = []
    @undos = []
    present("wrote a review", end_of(writer.block || last_block), end_of(writer.block || last_block))
  end

  # Stay for a while. The peer reports which blocks each update touched, and
  # never reports this agent's own edits. A changed block is highlighted; once
  # the typing pauses, a line addressed to @agent gets an answer or is acted
  # on, and any other change is considered. Between changes the agent does
  # its own work from its list, a few chunks at a time.
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

      index = changed.last
      @recent_changes = changed.dup
      while (more = @changes.pop(timeout: QUIET)) # let a burst of typing settle
        index = more.last || index
        @recent_changes |= more
      end
      next unless index && index < root.xml_text_count

      react_to(index)
      @changes.clear # what arrived while the agent was writing is not news
    end
  end

  # A line addressed to the agent is an instruction to edit or a question.
  # Anything else is the document changing under a collaborator: the agent
  # considers it and contributes only when that clearly helps.
  def react_to(index)
    line = block_text(index)
    case line
    when /\A@agent\s+undo\b/i then undo_last(index)
    when /\A@agent\s+edit\b/i then edit_document(index, line)
    when /\A@agent\s+(take|pause|resume|continue|stop)\b/i then handoff(index, line)
    when /\A@agent\s+draft\s+(this|the|here)\b/i then draft_here(index)
    when /\A@agent\b/i
      if scoped_request?(line)
        edit_selection(index, line)
      elsif !@answered.include?(line)
        answer(index, line)
      end
    else contribute(@recent_changes | [index])
    end
  end

  # Record and broadcast one diff, the way the channel does for a browser.
  def flush
    @flush ||= lambda do |update|
      next unless update

      Store.current.record(@document_id, update)
      Y::ActionCable.broadcast(@document_id, update)
    end
  end
end
