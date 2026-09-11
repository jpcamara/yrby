# frozen_string_literal: true

# How ReviewAgent reacts to a change: answer a question addressed to it, or
# note the change in its list.
module AgentReactions
  private

  def block_text(index) = root.xml_text(index).text.strip

  # Type the answer into a new paragraph right under the question.
  def answer(index, question)
    @answered << question
    present("answering", *block_selection(index))
    writer = StreamingWriter.new(doc, flush: flush, at: index + 1)
    stream_into(writer, "answering") { |emit| @reviewer.answer(question, text, &emit) }
    present("answered", end_of(writer.block), end_of(writer.block)) if writer.block
  end
end
