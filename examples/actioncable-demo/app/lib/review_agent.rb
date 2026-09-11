# frozen_string_literal: true

# A Ruby agent that joins a document as a live collaborator. It shows presence
# with a caret that walks the document while it reads, writes its review into
# the document as a heading and a paragraph, then parks the caret where it
# wrote. It is a plain loop: the presence is Y::Awareness, the reading is
# Doc#read_xml over a replay of the store, and the writing is Y::Lexical over
# Y::XmlText, recorded and broadcast like any other edit.
class ReviewAgent
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed" }.freeze

  def initialize(document_id, ticks: 16, pause: 4)
    @document_id = document_id
    @ticks = ticks
    @pause = pause
    @presence = Y::Awareness.new
    @wrote = false
  end

  def run
    @ticks.times do |tick|
      doc = replay
      root = doc.get_xml_text("root")
      words = doc.read_xml("root").to_s.split.size
      status = words.zero? ? "waiting for the first words" : "reviewing \u2014 #{words} words so far"
      caret = reading_caret(root, tick)

      if !@wrote && tick >= 2 && words.positive?
        write_review(doc, root, words)
        status = "wrote a review into the document"
        caret = end_of_last_block(root)
      end

      present(status, caret)
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

  # While reading, the caret sits at the end of one block per tick.
  def reading_caret(root, tick)
    return nil if root.xml_text_count.zero?

    end_of(root.xml_text(tick % root.xml_text_count))
  end

  def end_of_last_block(root)
    end_of(root.xml_text(root.xml_text_count - 1))
  end

  def end_of(block)
    block.relative_position(block.length)
  end

  # A heading and a paragraph in Lexical's own node shape, sent as a diff the
  # open editors apply like any remote edit.
  def write_review(doc, root, words)
    blocks = root.xml_text_count
    before = doc.encode_state_vector
    Y::Lexical.append_heading(doc, "Agent review", tag: "h2")
    Y::Lexical.append_paragraph(doc, "Read #{words} words across #{blocks} blocks. " \
                                     "The checklist reads clearly; every step has an owner implied by context. " \
                                     "One suggestion: name who signs off before the report is published.")
    update = doc.encode_state_as_update(before)
    Store.current.record(@document_id, update)
    Y::ActionCable.broadcast(@document_id, update)
    @wrote = true
  end

  def present(status, caret)
    state = IDENTITY.merge(awarenessData: IDENTITY, anchorPos: caret, focusPos: caret,
                           focusing: true, status: status)
    Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(state.to_json))
  end
end
