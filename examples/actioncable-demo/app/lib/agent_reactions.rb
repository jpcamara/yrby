# frozen_string_literal: true

# How ReviewAgent reacts to a change: answer a question addressed to it, or
# note the change in its list.
module AgentReactions
  private

  def block_text(index) = root.xml_text(index).text.strip

  # Every top-level block's text, and an anchor for each, taken together so
  # the numbers the model sees stay attached to the blocks they named.
  def numbered_blocks
    count = root.xml_text_count
    [(0...count).map { |i| root.xml_text(i).text }, (0...count).map { |i| root.xml_text(i).anchor }]
  end

  # Someone changed the document. Look at what changed, where people are,
  # and let the reviewer decide whether to add something small. Blocks
  # people are writing in are off limits.
  def contribute(changed)
    changed = changed.select { |i| i < root.xml_text_count }
    return if changed.empty?

    return if mine?(changed)

    avoid = (occupied_blocks | my_blocks).sort
    Rails.logger.info("agent: leaving alone #{avoid.inspect}, people #{people_here.inspect}")
    here = end_of(root.xml_text(changed.last))
    present("thinking about your change", here, here, sticky: true)
    blocks, anchors = numbered_blocks
    result = @reviewer.consider(changed, avoid, blocks)
    if result.edits.empty?
      present("left it alone", here, here, detail: result.note.presence)
    else
      apply_contribution(result, avoid, anchors)
    end
    @changes.clear
  end

  def apply_contribution(result, avoid, anchors)
    applied = DocumentEditor.new(doc, flush: flush, presence: self, avoid: avoid, anchors: anchors).apply(result.edits)
    return unless applied.applied.positive?

    remember_undo("what I added after your change", applied)
    present("added to what you wrote", end_of(last_block), end_of(last_block), detail: result.note.presence)
    note_in_review("Added after your change: #{result.note.presence || "a line"}")
  end

  # A change to the agent's own list means new work, not something to
  # consider; a change to a section it drafted hands that section over.
  def mine?(changed)
    if changed.intersect?(Worklist.ordinals(doc))
      @next_scan = 0
      here = end_of(root.xml_text(changed.last))
      present("saw your change to my list", here, here)
      return true
    end
    title = changed.filter_map { |i| my_section(i) }.first or return false
    @reviewer.remember("Someone edited my draft of \"#{title}\"; that section is theirs now")
    here = end_of(root.xml_text(changed.last))
    present("noted your edit to my draft", here, here, detail: "\"#{title}\" is yours now; I will leave it alone")
    true
  end

  # A short line in the agent's review list on each thing it did and why, so
  # the reasoning lives in the document as well as in the log.
  def note_in_review(text)
    list = @review_list && doc.find(@review_list) or return
    flush.call(doc.diff do
      item = list.push_xml_text(Y::Lexxy.list_item_attributes(list.xml_text_count + 1))
      item.insert_embed(0, Y::Lexical::TEXT_ATTRIBUTES)
      item.insert(1, text.to_s.gsub(/\s+/, " ").strip[0, 200])
    end)
  end

  # "@agent edit: <instruction>": take the instruction line out of the
  # document, ask for a plan over the numbered blocks that remain, and apply
  # it in place, block by block, visibly.
  def edit_document(index, line)
    instruction = line.sub(/\A@agent\s+edit\b:?\s*/i, "").strip
    instruction = "tighten the document and make it a proper checklist" if instruction.empty?
    show("taking your instruction", root.xml_text(index))
    flush.call(doc.diff { root.delete_xml_text(index) })
    blocks, anchors = numbered_blocks
    present("planning edits", nil, nil)
    plan = @reviewer.edits(instruction, blocks)
    result = DocumentEditor.new(doc, flush: flush, presence: self, anchors: anchors).apply(plan)
    remember_undo("the edit: #{instruction}", result)
    present("edited #{result.applied} blocks", end_of(last_block), end_of(last_block))
    note_in_review("Edited #{result.applied} blocks on request: #{instruction}")
    @changes.clear
  end

  # A request that says "this": rewrite what the person last selected, or
  # the block just above the request, and nothing else.
  def scoped_request?(line)
    !line.end_with?("?") && line.match?(/\b(this|these|that|the selection|selected)\b/i)
  end

  def edit_selection(index, line)
    scope = selection_for(index)
    return answer(index, line) unless scope

    instruction = line.sub(/\A@agent\s*:?\s*/i, "").strip
    from, to = take_request(index, scope)
    return present("what you selected is gone", nil, nil) unless from && to

    blocks, anchors = numbered_blocks
    present("rewriting your selection", block_selection(from).first, end_of(root.xml_text(to)))
    plan = @reviewer.edits(instruction, blocks, only: from..to)
    result = DocumentEditor.new(doc, flush: flush, presence: self, anchors: anchors).apply(plan)
    remember_undo(from == to ? "the rewrite of block #{from}" : "the rewrite of blocks #{from}-#{to}", result)
    present("rewrote #{result.applied} #{result.applied == 1 ? "block" : "blocks"} you selected",
            end_of(last_block), end_of(last_block))
    @changes.clear
  end

  # Take the request line out of the document and say where the scoped
  # blocks are without it.
  def take_request(index, scope)
    show("taking your request", root.xml_text(index))
    first, last = scope.map { |i| root.xml_text(i).anchor }
    flush.call(doc.diff { root.delete_xml_text(index) })
    [doc.block_at(first), doc.block_at(last)]
  end

  # "@agent undo": put back whatever the agent did last.
  def undo_last(index)
    show("undoing", root.xml_text(index))
    flush.call(doc.diff { root.delete_xml_text(index) })
    last = @undos.pop
    return present("nothing of mine to undo", nil, nil) unless last

    result = DocumentEditor.new(doc, flush: flush, presence: self).revert(last[:steps])
    gone = if result.skipped.positive?
             ", #{result.skipped} #{result.skipped == 1 ? "part was" : "parts were"} already gone"
           else
             ""
           end
    @reviewer.remember("Undid #{last[:label]}") if @reviewer.respond_to?(:remember)
    present("undid #{last[:label]}#{gone}", nil, nil)
    @changes.clear
  end

  def remember_undo(label, result)
    @undos << { label: label, steps: result.undo } if result.undo.any?
  end

  # Type the answer into a new paragraph right under the question.
  def answer(index, question)
    @answered << question
    present("answering", end_of(root.xml_text(index)), end_of(root.xml_text(index)), sticky: true)
    writer = StreamingWriter.new(doc, flush: flush, after: root.xml_text(index).anchor)
    stream_into(writer, "answering") { |emit| @reviewer.answer(question, text, &emit) }
    present("answered", end_of(writer.block), end_of(writer.block)) if writer.block
  end

  # Feed a stream of chunks into `writer`. The block receives `emit`, a proc
  # to hand each chunk to; the caret moves to the end of the text a few times
  # a second so people see the agent writing.
  # The model's chunks go through a pacer so the text arrives at a steady
  # pace rather than in the bursts the model produces them in.
  def stream_into(writer, status)
    since = 0
    pacer = Pacer.new { |piece| writer.feed(piece) }
    follow = lambda do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next unless writer.block && now - since > 0.25

      present(status, end_of(writer.block), end_of(writer.block), sticky: true)
      since = now
    end
    emit = lambda do |chunk|
      pacer.feed(chunk)
      while pacer.pending?
        pacer.drain
        follow.call
        sleep 0.03 if pacer.pending?
      end
    end
    yield emit
    pacer.flush
    writer.finish
  end
end
