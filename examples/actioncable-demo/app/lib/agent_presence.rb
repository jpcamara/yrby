# frozen_string_literal: true

# How ReviewAgent shows itself: a caret or a selection, published as awareness.
module AgentPresence
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed" }.freeze
  STATUS_TTL = 8 # seconds a passing status stays on the label before "listening"
  HEARTBEAT = 5  # seconds between presence refreshes; editors forget a peer after 30

  # Highlight `block` with a status, the way the editor shows what it is
  # about to change.
  def show(status, block)
    present(status, block.relative_position([1, block.length].min), block.relative_position(block.length))
  end

  # Move the caret to the end of `block` a few times a second while typing.
  def follow(block)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if @followed_at && now - @followed_at < 0.25

    @followed_at = now
    present(@last_presence ? @last_presence[:status] : "editing", block.relative_position([1, block.length].min),
            block.relative_position(block.length))
  end

  # Ordinals of the blocks other people are writing in, from their presence:
  # each peer's caret is a relative position, and the document says which
  # block it falls in. The agent's own presence is left out.
  IDLE = 60 # seconds without the caret moving before a person no longer holds a block
  GONE = 45 # seconds without a presence renewal before a person counts as gone

  # Blocks people are writing in: their caret or selection moved within the
  # last minute. Lexxy keeps `focusing: true` after a blur, so a parked caret
  # would otherwise hold a block for good.
  def occupied_blocks
    return [] unless @others

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.flat_map do |client, state|
      next [] if client == @presence.client_id || !state.is_a?(Hash) || state["focusing"] == false
      next [] if now - @moved_at.fetch(client, now) > IDLE || gone?(client, now)

      %w[anchorPos focusPos].filter_map { |k| state[k].is_a?(Hash) ? doc.block_at(state[k], "root") : nil }
    end.uniq.sort
  end

  # Who is here, by name, from their presence.
  def people_here
    return [] unless @others

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.filter_map do |client, s|
      s["name"] if client != @presence.client_id && s.is_a?(Hash) && !gone?(client, now)
    end.uniq
  end

  # Feed a presence frame the peer received into the mirror of everyone's
  # state, and remember what each person last had selected.
  def see_presence(frame)
    (@others ||= Y::Awareness.new).apply_update(frame)
    note_renewals
    note_movement
    note_selections
  end

  SELECTION_MEMORY = 120 # seconds a selection stays the meaning of "this"

  # The blocks the author of the line at `index` meant by "this": what they
  # last selected, if it was recent, else the block just above the line.
  # The author is whoever has their caret in that line.
  def selection_for(index)
    remembered = remembered_selection(author_of(index))
    return remembered if remembered

    [index - 1, index - 1] if index.positive?
  end

  # The client whose caret is in block `index`.
  def author_of(index)
    return unless @others

    @others.states.find do |client, state|
      client != @presence.client_id && state.is_a?(Hash) && position_block(state["anchorPos"]) == index
    end&.first
  end

  # What a client last selected, as the block range it covers now, if recent
  # and still there.
  def remembered_selection(client)
    remembered = client && @selections&.dig(client)
    return unless remembered && Process.clock_gettime(Process::CLOCK_MONOTONIC) - remembered[:at] < SELECTION_MEMORY

    blocks = remembered[:anchors].map { |a| doc.block_at(a) }
    blocks.minmax if blocks.all?
  end

  private

  # When each client last renewed its presence: its awareness clock moved. A
  # browser that closed without saying so stops renewing, and after GONE
  # seconds it no longer counts as here or as holding a block.
  def note_renewals
    @seen_at ||= {}
    @clocks ||= {}
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.clocks.each do |client, clock|
      next if @clocks[client] == clock

      @clocks[client] = clock
      @seen_at[client] = now
    end
  end

  def gone?(client, now) = now - @seen_at.fetch(client, now) > GONE

  # When each person's caret or selection last changed. Renewal frames repeat
  # the same positions and do not count.
  def note_movement
    @moved_at ||= {}
    @positions ||= {}
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.each do |client, state|
      next unless state.is_a?(Hash)

      position = [state["anchorPos"], state["focusPos"]]
      next if @positions[client] == position

      @positions[client] = position
      @moved_at[client] = now
    end
  end

  # A non-collapsed selection is remembered per client, as anchors, so it
  # still names the same blocks after edits above it.
  def note_selections
    @selections ||= {}
    @others.states.each do |client, state|
      next if client == @presence.client_id || !state.is_a?(Hash)
      next if state["anchorPos"] == state["focusPos"]

      first, last = [position_block(state["anchorPos"]), position_block(state["focusPos"])].compact.minmax
      next unless first && last < root.xml_text_count

      anchors = [root.xml_text(first).anchor, root.xml_text(last).anchor]
      @selections[client] = { anchors: anchors, at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end
  end

  def position_block(position)
    doc.block_at(position, "root") if position.is_a?(Hash)
  end

  def block_selection(index)
    return [nil, nil] if root.xml_text_count.zero?

    block = root.xml_text(index)
    [block.relative_position([1, block.length].min), end_of(block)]
  end

  def last_block = root.xml_text(root.xml_text_count - 1)
  def end_of(block) = block.relative_position(block.length)

  # Say what the agent is doing, where its caret is. The status goes into the
  # cursor label, so people see it where they are looking; `detail:` is the
  # fuller reason for the log under the editor. A status is either sticky
  # (drafting, waiting, paused, listening) or fades to "listening" after a
  # few seconds.
  def present(status, anchor, focus, detail: nil, sticky: false)
    Rails.logger.info("agent: #{status}#{" — #{detail}" if detail}")
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize do
      @last_presence = IDENTITY.merge(name: "#{IDENTITY[:name]} · #{status}", awarenessData: IDENTITY,
                                      anchorPos: anchor, focusPos: focus, focusing: true,
                                      status: status, detail: detail, at: (Time.now.to_f * 1000).to_i)
      @status_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @sticky = sticky
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  # Editors drop a peer they have not heard from in a while; say it again.
  def keep_alive
    return unless @last_presence

    @presence_lock.synchronize do
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  # A thread that keeps the agent in the roster through a slow model call and
  # lets a passing status fade.
  def start_heartbeat
    @heartbeat = Thread.new do
      loop do
        sleep HEARTBEAT
        if @last_presence && !@sticky && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @status_at > STATUS_TTL
          present("listening", @last_presence[:anchorPos], @last_presence[:focusPos], sticky: true)
        else
          keep_alive
        end
      rescue StandardError => e
        Rails.logger.warn("agent heartbeat: #{e.class}: #{e.message}")
      end
    end
  end

  def stop_heartbeat = @heartbeat&.kill
end
