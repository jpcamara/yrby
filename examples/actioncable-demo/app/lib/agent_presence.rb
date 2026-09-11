# frozen_string_literal: true

# How ReviewAgent shows itself: a caret or a selection, published as awareness.
module AgentPresence
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed" }.freeze

  private

  def block_selection(index)
    return [nil, nil] if root.xml_text_count.zero?

    block = root.xml_text(index)
    [block.relative_position([1, block.length].min), end_of(block)]
  end

  def last_block = root.xml_text(root.xml_text_count - 1)
  def end_of(block) = block.relative_position(block.length)

  def present(status, anchor, focus)
    Rails.logger.info("agent: #{status}")
    @last_presence = IDENTITY.merge(awarenessData: IDENTITY, anchorPos: anchor, focusPos: focus,
                                    focusing: true, status: status)
    Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
  end

  # Editors drop a peer they have not heard from in a while; say it again.
  def keep_alive
    return unless @last_presence

    Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
  end
end
