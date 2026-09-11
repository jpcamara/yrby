# frozen_string_literal: true

# A Ruby agent that joins a document as a live collaborator. It follows the
# document through a Y::ActionCable::Peer, one live doc for the whole run,
# so it sees people's edits as they happen. While it reads it highlights one
# block per tick, walking down the document. Then it types its review into the
# document as the reviewer produces it: a heading, a paragraph, and a list.
# After that it keeps watching: when someone changes a block it highlights
# the change, and once they pause it adds a note to its list. The presence is
# Y::Awareness; the writing is Y::Lexical over Y::XmlText, recorded and
# broadcast like any other edit.
class ReviewAgent
  include AgentPresence
  include AgentReactions

  QUIET = 1.5 # seconds without further edits before the agent notes a change
  KEEP_ALIVE = 15 # presence expires in editors after 30s of silence; refresh before that

  def initialize(document_id, reviewer: Reviewer.default, ticks: 3, pause: 4, watch: 90)
    @document_id = document_id
    @reviewer = reviewer
    @ticks = ticks
    @pause = pause
    @watch = watch
    @presence = Y::Awareness.new
    @changes = Queue.new
    @peer = Y::ActionCable::Peer.new(document_id)
    @list = nil
  end

  def run
    @peer.on_update { |_update, _doc, changed| @changes << changed }
    @peer.subscribe
    (bytes = Store.current.replay(@document_id)) && doc.apply_update(bytes)
    read
    write_review
    watch
  ensure
    @peer.unsubscribe
    Y::ActionCable.broadcast_awareness(@document_id, @presence.clear_local_state)
  end

  private

  def doc = @peer.doc
  def root = doc.get_xml_text("root")
  def text = doc.read_xml("root").to_s

  # Look at the document a few times, one block highlighted per tick.
  def read
    @ticks.times do |tick|
      words = text.split.size
      status = words.zero? ? "waiting for the first words" : "reviewing — #{words} words so far"
      present(status, *block_selection(tick % [root.xml_text_count, 1].max))
      sleep @pause
    end
  end

  # The review, typed into the document as the reviewer produces it. Every
  # insert is a diff the open editors apply, so people watch the agent write.
  def write_review
    flush.call(doc.diff { Y::Lexical.append_heading(doc, "Agent review", tag: "h2") })
    writer = StreamingWriter.new(doc, flush: flush)
    stream_into(writer, "writing a review into the document") { |emit| @reviewer.stream(text, &emit) }
    @list = writer.list
    @answered = []
    present("wrote a review into the document", end_of(last_block), end_of(last_block))
  end

  # Stay for a while. The peer reports which blocks each update touched, and
  # never reports this agent's own edits. A changed block is highlighted; once
  # the typing pauses, a line addressed to @agent gets an answer written right
  # below it, and any other change gets a note in the list.
  def watch
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @watch
    while (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
      changed = @changes.pop(timeout: [remaining, KEEP_ALIVE].min)
      next keep_alive unless changed

      index = changed.last
      present("reading your change", *block_selection(index)) if index && index < root.xml_text_count
      while (more = @changes.pop(timeout: QUIET)) # let a burst of typing settle
        index = more.last || index
      end
      next unless index && index < root.xml_text_count

      question = block_text(index)
      if question.match?(/\A@agent\b/i)
        answer(index, question) unless @answered.include?(question)
      else
        note_change(index)
      end
      @changes.clear # what arrived while the agent was writing is not news
    end
  end

  # Feed a stream of chunks into `writer`. The block receives `emit`, a proc
  # to hand each chunk to; the caret moves to the end of the text a few times
  # a second so people see the agent writing.
  def stream_into(writer, status)
    since = 0
    emit = lambda do |chunk|
      writer.feed(chunk)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next unless writer.block && now - since > 0.25

      present(status, end_of(writer.block), end_of(writer.block))
      since = now
    end
    yield emit
    writer.finish
  end

  def note_change(index)
    snippet = block_text(index).then { |s| s.length > 40 ? "#{s[0, 40]}…" : s }
    return if snippet.empty? || snippet.start_with?("Saw your change")

    flush.call(doc.diff do
      @list ||= Y::Lexxy.append_list(doc, [])
      item = @list.push_xml_text(Y::Lexxy.list_item_attributes(@list.xml_text_count + 1))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
      item.insert(1, "Saw your change to “#{snippet}”.")
    end)
    present("noted your change", end_of(last_block), end_of(last_block))
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
