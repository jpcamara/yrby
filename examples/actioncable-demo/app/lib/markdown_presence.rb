# frozen_string_literal: true

# Presence for the markdown agent over y-codemirror's awareness shape: a
# person is `{user: {name, color}, cursor: {anchor, head}}` with relative
# positions into the Y.Text. The agent publishes the same, with its status in
# the name (the cursor label) and `status`/`detail`/`at` for the log.
module MarkdownPresence
  IDENTITY = { name: "Agent \u{1F916}", color: "#7c3aed", colorLight: "rgba(124, 58, 237, .28)" }.freeze
  STATUS_TTL = 8
  HEARTBEAT = 5
  THINKING_KEEP = 6000
  IDLE = 60
  GONE = 45

  # Lines people are writing on: their caret or selection moved within the
  # last minute and their presence is still renewing.
  def occupied_lines
    return [] unless @others

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.flat_map do |client, state|
      next [] if client == @presence.client_id || !state.is_a?(Hash)
      next [] if now - @moved_at.fetch(client, now) > IDLE || gone?(client, now)

      cursor = state["cursor"]
      next [] unless cursor.is_a?(Hash)

      %w[anchor head].filter_map do |k|
        cursor[k].is_a?(Hash) ? line_of(@doc.index_at(cursor[k], @text.root_name)) : nil
      end
    end.uniq.sort
  end

  def people_here
    return [] unless @others

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.filter_map do |client, s|
      s.dig("user", "name") if client != @presence.client_id && s.is_a?(Hash) && !gone?(client, now)
    end.uniq
  end

  def see_presence(frame)
    (@others ||= Y::Awareness.new).apply_update(frame)
    note_renewals
    note_movement
  end

  private

  def line_of(index)
    return unless index

    @text.to_s.byteslice(0, index).to_s.count("\n")
  end

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

  def note_movement
    @moved_at ||= {}
    @positions ||= {}
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.each do |client, state|
      next unless state.is_a?(Hash)

      position = state["cursor"]
      next if @positions[client] == position

      @positions[client] = position
      @moved_at[client] = now
    end
  end

  # Say what the agent is doing with its caret at character `index` (or a
  # selection from `index` to `to`).
  def present(status, index, to = nil, detail: nil, sticky: false)
    Rails.logger.info("agent: #{status}#{" — #{detail}" if detail}")
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize do
      anchor = index && @text.relative_position([index, @text.length].min)
      head = to ? @text.relative_position([to, @text.length].min) : anchor
      @thinking = +"" unless @last_presence && @last_presence[:status] == status
      @last_presence = {
        user: IDENTITY.merge(name: "#{IDENTITY[:name]} · #{status}"), identity: IDENTITY,
        cursor: anchor ? { anchor: anchor, head: head } : nil,
        status: status, detail: detail, thinking: @thinking.presence, at: (Time.now.to_f * 1000).to_i
      }
      @last_index = index
      @status_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @sticky = sticky
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  def think(delta)
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize do
      @thinking = (@thinking.to_s + delta)[-THINKING_KEEP..] || (@thinking.to_s + delta)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next if @last_presence.nil? || (@thought_at && now - @thought_at < 0.3)

      @thought_at = now
      @last_presence = @last_presence.merge(thinking: @thinking)
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  def keep_alive
    return unless @last_presence

    @presence_lock.synchronize do
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  def start_heartbeat
    @heartbeat = Thread.new do
      loop do
        sleep HEARTBEAT
        if @last_presence && !@sticky && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @status_at > STATUS_TTL
          present("listening", @last_index, sticky: true)
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
