# frozen_string_literal: true

# A Ruby agent that joins a document as a live collaborator. While it reads it
# highlights one block per tick, walking down the document; then it writes its
# review into the document as a heading, a paragraph, and a list, and parks
# its caret where it wrote. It is a plain loop: the presence is Y::Awareness,
# the reading is Doc#read_xml over a replay of the store, the review comes
# from a Reviewer (a model when a key is present), and the writing is
# Y::Lexical over Y::XmlText, recorded and broadcast like any other edit.
class ReviewAgent
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed" }.freeze

  def initialize(document_id, reviewer: Reviewer.default, ticks: 16, pause: 4)
    @document_id = document_id
    @reviewer = reviewer
    @ticks = ticks
    @pause = pause
    @presence = Y::Awareness.new
    @wrote = false
  end

  def run
    @ticks.times do |tick|
      doc = replay
      root = doc.get_xml_text("root")
      text = doc.read_xml("root").to_s
      words = text.split.size
      status = words.zero? ? "waiting for the first words" : "reviewing \u2014 #{words} words so far"
      anchor, focus = reading_selection(root, tick)

      if !@wrote && tick >= 2 && words.positive?
        write_review(doc, root, text)
        status = "wrote a review into the document"
        anchor = focus = end_of_last_block(root)
      end

      present(status, anchor, focus)
      sleep @pause
    end
    Y::ActionCable.broadcast_awareness(@document_id, @presence.clear_local_state)
  end

  private

  # The shared document, read the way any Ruby process would: a fresh replay
  # of the store, which holds every edit that has been acknowledged.
  def replay
    doc = Y::Doc.new
    (bytes = Store.current.replay(@document_id)) && doc.apply_update(bytes)
    doc
  end

  # While reading, one block per tick is selected: from the start of its text
  # (index 1, after the text node's marker) to its end. An editor draws that as
  # a highlight in the agent's color.
  def reading_selection(root, tick)
    return [nil, nil] if root.xml_text_count.zero?

    block = root.xml_text(tick % root.xml_text_count)
    start = block.relative_position([1, block.length].min)
    [start, end_of(block)]
  end

  def end_of_last_block(root)
    end_of(root.xml_text(root.xml_text_count - 1))
  end

  def end_of(block)
    block.relative_position(block.length)
  end

  # The review, in Lexical's own node shape: a heading, a paragraph, and a
  # list, sent as a diff the open editors apply like any remote edit.
  def write_review(doc, root, text)
    review = @reviewer.call(text)
    before = doc.encode_state_vector
    Y::Lexical.append_heading(doc, "Agent review", tag: "h2")
    Y::Lexical.append_paragraph(doc, review.summary)
    Y::Lexxy.append_list(doc, review.suggestions) if review.suggestions.any?
    update = doc.encode_state_as_update(before)
    Store.current.record(@document_id, update)
    Y::ActionCable.broadcast(@document_id, update)
    @wrote = true
    root
  end

  def present(status, anchor, focus)
    state = IDENTITY.merge(awarenessData: IDENTITY, anchorPos: anchor, focusPos: focus,
                           focusing: true, status: status)
    Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(state.to_json))
  end
end
