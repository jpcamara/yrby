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
    present("thinking about your change", *block_selection(changed.last))
    blocks, anchors = numbered_blocks
    result = @reviewer.consider(changed, avoid, blocks)
    if result.edits.empty?
      present(result.note.presence || "nothing to add", *block_selection(changed.last))
    else
      applied = DocumentEditor.new(doc, flush: flush, presence: self, avoid: avoid,
                                        anchors: anchors).apply(result.edits)
      if applied.applied.positive?
        remember_undo("what I added after your change", applied)
        present(result.note.presence || "added to what you wrote", end_of(last_block),
                end_of(last_block))
      end
    end
    @changes.clear
  end

  # A change to the agent's own list means new work, not something to
  # consider; a change to a section it drafted hands that section over.
  def mine?(changed)
    if changed.intersect?(Worklist.ordinals(doc))
      @next_scan = 0
      present("saw your change to my list", *block_selection(changed.last))
      return true
    end
    title = changed.filter_map { |i| my_section(i) }.first or return false
    @reviewer.remember("Someone edited my draft of \"#{title}\"; that section is theirs now")
    present("noted your change to my draft of #{title}", *block_selection(changed.last))
    true
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
    present("answering", *block_selection(index))
    writer = StreamingWriter.new(doc, flush: flush, after: root.xml_text(index).anchor)
    stream_into(writer, "answering") { |emit| @reviewer.answer(question, text, &emit) }
    present("answered", end_of(writer.block), end_of(writer.block)) if writer.block
  end
end
