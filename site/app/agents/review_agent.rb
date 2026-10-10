# What the demo agent does once Y::Agent has it in a room. It says hello,
# reviews what's already written, and answers any line that starts with
# "@agent". Replies stream into the document as the model writes them, with
# the agent's caret at the end of the words, so people watch it type.
class ReviewAgent
  NAME = "Agent".freeze
  COLOR = "#7c3aed".freeze
  IDENTITY = { "name" => NAME, "color" => COLOR }.freeze
  HELLO = "Hi, I'm the demo agent. Start a line with @agent to ask me something.".freeze
  ASK = /\A\s*@agent\b[\s,:]*(.*)\z/im
  CARET_EVERY = 0.25 # seconds between caret moves while writing
  DOCUMENT_LIMIT = 6000 # characters of the document sent to the model

  def initialize(agent, model: AgentModel.default)
    @agent = agent
    @model = model
    @answered = []
  end

  def start
    @agent.on_change { |blocks| blocks.each { |index| answer(index) } }
    text = document_text # what people wrote, before the agent adds anything
    write_paragraph { |write| write.call(HELLO) }
    return if text.length < 20

    write_paragraph { |write| @model.review(text) { |chunk| write.call(chunk) } }
  end

  private

  def root = @agent.doc.get_xml_text("root")

  def document_text = @agent.doc.read_xml("root").to_s.strip[0, DOCUMENT_LIMIT]

  # Answers block `index` if it asks the agent something and hasn't been
  # answered. A request counts as finished once it ends a sentence or the
  # person has moved on to the next line, so a pause mid-question doesn't
  # get a reply to half of it.
  def answer(index)
    return if index >= root.xml_text_count

    block = root.xml_text(index)
    question = block.text.to_s[ASK, 1].to_s.strip
    return if question.empty? || @answered.include?(block.anchor) || !finished?(question, index)

    @answered << block.anchor
    write_paragraph(after: block.anchor) do |write|
      @model.answer(question, document_text) { |chunk| write.call(chunk) }
    end
  end

  def finished?(question, index) = question.match?(/[?.!]\z/) || index < root.xml_text_count - 1

  # Adds a paragraph, at the end or under the block `after:` anchors, and
  # yields a writer that appends to it. The paragraph is found by its anchor
  # on every write, so it stays put while people edit above it. A model
  # failure is written into the paragraph.
  def write_paragraph(after: nil)
    anchor = nil
    @agent.edit do |doc|
      at = after && doc.block_at(after)
      block = at ? Y::Lexxy.insert_paragraph(doc, at + 1, "") : Y::Lexxy.append_paragraph(doc, "")
      anchor = block.anchor
    end
    yield ->(text) { append(anchor, text) }
  rescue AgentModel::Error => e
    append(anchor, "(The agent couldn't answer: #{e.message}.)") if anchor
  ensure
    @agent.presence = IDENTITY.merge("focusing" => false)
  end

  def append(anchor, text)
    @agent.edit do |doc|
      block = doc.find(anchor)
      block&.insert(block.length, text)
    end
    move_caret(anchor)
  end

  # The caret sits at the end of what the agent is writing.
  def move_caret(anchor)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if @caret_at && now - @caret_at < CARET_EVERY

    block = @agent.doc.find(anchor) or return
    @caret_at = now
    position = block.relative_position(block.length)
    @agent.presence = IDENTITY.merge("anchorPos" => position, "focusPos" => position, "focusing" => true)
  end
end
