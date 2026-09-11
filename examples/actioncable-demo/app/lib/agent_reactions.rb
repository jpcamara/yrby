# frozen_string_literal: true

# How ReviewAgent reacts to a change: answer a question addressed to it, or
# note the change in its list.
module AgentReactions
  private

  def block_text(index) = root.xml_text(index).text.strip

  # "@agent edit: <instruction>": take the instruction line out of the
  # document, ask for a plan over the numbered blocks that remain, and apply
  # it in place, block by block, visibly.
  def edit_document(index, line)
    instruction = line.sub(/\A@agent\s+edit\b:?\s*/i, "").strip
    instruction = "tighten the document and make it a proper checklist" if instruction.empty?
    show("taking your instruction", root.xml_text(index))
    flush.call(doc.diff { root.delete_xml_text(index) })
    blocks = (0...root.xml_text_count).map { |i| root.xml_text(i).text }
    present("planning edits", nil, nil)
    plan = @reviewer.edits(instruction, blocks)
    result = DocumentEditor.new(doc, flush: flush, presence: self).apply(plan)
    present("edited #{result.applied} blocks", end_of(last_block), end_of(last_block))
    @changes.clear
  end

  # Type the answer into a new paragraph right under the question.
  def answer(index, question)
    @answered << question
    present("answering", *block_selection(index))
    writer = StreamingWriter.new(doc, flush: flush, at: index + 1)
    stream_into(writer, "answering") { |emit| @reviewer.answer(question, text, &emit) }
    present("answered", end_of(writer.block), end_of(writer.block)) if writer.block
  end
end
