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
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed" }.freeze
  QUIET = 1.5 # seconds without further edits before the agent notes a change

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
    @peer.on_update { |_update, _doc| @changes << Process.clock_gettime(Process::CLOCK_MONOTONIC) }
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
    since = 0
    @reviewer.stream(text) do |chunk|
      writer.feed(chunk)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next unless writer.block && now - since > 0.25

      present("writing a review into the document", end_of(writer.block), end_of(writer.block))
      since = now
    end
    writer.finish
    @list = writer.list
    @seen = text.lines
    present("wrote a review into the document", end_of(last_block), end_of(last_block))
  end

  # Stay for a while. A change from anyone else (the peer never reports this
  # agent's own edits) highlights the block that changed; when the edits pause,
  # the agent notes it in its list.
  def watch
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @watch
    while (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
      next unless @changes.pop(timeout: [remaining, QUIET].min)

      index = changed_block
      present("reading your change", *block_selection(index)) if index
      sleep QUIET while @changes.pop(timeout: QUIET) # let a burst of typing settle
      note_change(index) if index
    end
  end

  # The first block whose text differs from the last time the agent looked.
  def changed_block
    now = text.lines
    index = now.each_index.find { |i| now[i] != @seen[i] } || (now.size > @seen.size ? now.size - 1 : nil)
    @seen = now
    index
  end

  def note_change(index)
    snippet = @seen[index].to_s.strip.then { |s| s.length > 40 ? "#{s[0, 40]}…" : s }
    flush.call(doc.diff do
      @list ||= Y::Lexxy.append_list(doc, [])
      item = @list.push_xml_text(Y::Lexxy.list_item_attributes(@list.xml_text_count + 1))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
      item.insert(1, "Saw your change to “#{snippet}”.")
    end)
    @seen = text.lines
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

  def block_selection(index)
    return [nil, nil] if root.xml_text_count.zero?

    block = root.xml_text(index)
    [block.relative_position([1, block.length].min), end_of(block)]
  end

  def last_block = root.xml_text(root.xml_text_count - 1)
  def end_of(block) = block.relative_position(block.length)

  def present(status, anchor, focus)
    state = IDENTITY.merge(awarenessData: IDENTITY, anchorPos: anchor, focusPos: focus,
                           focusing: true, status: status)
    Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(state.to_json))
  end
end
