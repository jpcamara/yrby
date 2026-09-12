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
    note_selections
  rescue StandardError => e
    Rails.logger.warn("agent presence: #{e.class}: #{e.message} @ #{e.backtrace&.first}")
  end

  SELECTION_MEMORY = 120 # seconds a selection stays the meaning of "this"

  # The byte range the author of the line at `line` meant by "this": what
  # they last selected, if recent and still there, else nil.
  def selection_for(line)
    client = author_of(line) or return
    remembered = @selections&.dig(client) or return
    return if Process.clock_gettime(Process::CLOCK_MONOTONIC) - remembered[:at] > SELECTION_MEMORY

    from = @doc.index_at(remembered[:start], @text.root_name)
    to = @doc.index_at(remembered[:end], @text.root_name)
    [from, to].minmax if from && to && from != to
  end

  # The client whose caret is on `line`.
  def author_of(line)
    return unless @others

    @others.states.find do |client, state|
      next false if client == @presence.client_id || !state.is_a?(Hash)

      head = state.dig("cursor", "head")
      head.is_a?(Hash) && line_of(@doc.index_at(head, @text.root_name)) == line
    end&.first
  end

  LEDGER = "agent-log" # the ledger, a Y.Array in the document
  LEDGER_KEEP = 200

  private

  def line_of(index)
    return unless index

    @text.to_s.byteslice(0, index).to_s.count("\n")
  end

  # A non-collapsed selection is remembered per client as two anchors, so it
  # still names the same text after edits above it.
  def note_selections
    @selections ||= {}
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @others.states.each do |client, state|
      next if client == @presence.client_id || !state.is_a?(Hash)

      cursor = state["cursor"]
      next unless cursor.is_a?(Hash) && cursor["anchor"].is_a?(Hash) && cursor["head"].is_a?(Hash)

      a = @doc.index_at(cursor["anchor"], @text.root_name)
      h = @doc.index_at(cursor["head"], @text.root_name)
      next unless a && h && a != h

      from, to = [a, h].minmax
      @selections[client] = { start: @text.relative_position(from, assoc: :before),
                              end: @text.relative_position(to, assoc: :after), at: now }
    end
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
  def present(status, index, to = nil, detail: nil, sticky: false, log: true) # rubocop:disable Metrics/ParameterLists
    log_entry(status, detail) if log
    Rails.logger.info("agent: #{status}#{" — #{detail}" if detail}")
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize do
      anchor = index && @text.relative_position([index, @text.length].min)
      head = to ? @text.relative_position([to, @text.length].min) : anchor
      turn_thinking(status)
      @last_presence = {
        user: IDENTITY.merge(name: "#{IDENTITY[:name]} · #{status}"), identity: IDENTITY,
        cursor: anchor ? { anchor: anchor, head: head } : nil,
        status: status, detail: detail, thinking: @thinking.presence&.dup, at: (Time.now.to_f * 1000).to_i
      }
      @last_index = index
      @status_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @sticky = sticky
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  # Reasoning, kept per stream: a review and a draft running together each
  # show their own. A stream names itself through the thread it runs in; a
  # call made from the loop is filed under the current status, and dropped
  # when the status moves on.
  def think(delta)
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize do
      label = Thread.current[:agent_purpose] || @last_presence&.dig(:status) || "thinking"
      @thinking ||= {}
      @thinking[label] = ((@thinking[label] || "") + delta)[-THINKING_KEEP..] || ((@thinking[label] || "") + delta)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next if @last_presence.nil? || (@thought_at && now - @thought_at < 0.3)

      @thought_at = now
      @last_presence = @last_presence.merge(thinking: @thinking.dup)
      Y::ActionCable.broadcast_awareness(@document_id, @presence.set_local_state(@last_presence.to_json))
    end
  end

  # A stream is done: its reasoning stays in the ledger where it was, and the
  # next stream with the same name starts fresh.
  def forget_thinking(label)
    @presence_lock ||= Mutex.new
    @presence_lock.synchronize { @thinking&.delete(label) }
  end

  # Reasoning filed under a status goes when the status changes; a running
  # stream's stays.
  def turn_thinking(status)
    return if @last_presence && @last_presence[:status] == status

    (@thinking ||= {}).delete_if { |label, _| !StreamJob.running?(label) }
  end

  # The caret moves with every step of a stream. Say so a few times a second
  # at most, and not at all when nothing moved.
  def present_caret(status, *where, **)
    return if status.blank?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    key = [status, where]
    unchanged = @last_presence && @last_presence[:status] == status
    return if unchanged && (@caret_key == key || now - @caret_at < 0.25)

    @caret_key = key
    @caret_at = now
    present(status, *where, **, log: false)
  end

  # The ledger, kept in the document: a Y.Array of {at, status, detail}
  # entries, so every page shows the same history and a reload keeps it.
  def log_entry(status, detail)
    entries = @doc.get_array(LEDGER)
    update = @doc.diff do
      entries.push({ "at" => (Time.now.to_f * 1000).to_i, "status" => status, "detail" => detail })
      entries.delete_at(0) while entries.size > LEDGER_KEEP
    end
    flush.call(update) if update
  rescue StandardError => e
    Rails.logger.warn("agent ledger: #{e.class}: #{e.message}")
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
          present(@paused ? "paused" : "listening", @last_index, sticky: true, log: false)
        else
          keep_alive
        end
      rescue StandardError => e
        Rails.logger.warn("agent heartbeat: #{e.class}: #{e.message}")
      end
    end
  end

  def stop_heartbeat = @heartbeat&.kill

  # A model failure, said where people can see it instead of passed off as
  # the agent's own words. `what` is the thing that did not happen.
  def report_failure(what, error, then_what = nil)
    reason = error.is_a?(LlmReviewer::ModelError) ? error.message : LlmReviewer.describe(error)
    Rails.logger.warn("agent: #{what} failed: #{error.class}: #{error.message}")
    present("couldn't finish #{what}", @last_index || @text.length, detail: [reason, then_what].compact.join("; "))
    @backoff_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  end

  # After a failure, the agent leaves passing changes alone for a while.
  def backing_off?
    @backoff_until && Process.clock_gettime(Process::CLOCK_MONOTONIC) < @backoff_until
  end
end
