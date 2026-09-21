# frozen_string_literal: true

# Pixel Bay in browser Ruby. The reusable Yrby::Wasm client owns document sync,
# delivery and presence; this file owns the same UI as the JavaScript studio.
class PixelBrowser
  WIDTH = 64
  HEIGHT = 32
  COLORS = %w[#1d2038 #38415d #697a91 #b4c3ce #f6eedb #ffffff #c85b50 #f27c63 #f6bb6a #ffe7a0 #447a70 #78b38b #36699b #66a4cc #9b78aa #d69bbd].freeze
  NAMES = ["Midnight", "Slate", "Fog", "Silver", "Cream", "White", "Bridge red", "Coral", "Apricot", "Sunshine", "Evergreen", "Sage", "Ocean", "Sky", "Lavender", "Rose"].freeze
  ORIGIN = "pixel-bay-human"
  attr_reader :client

  def initialize
    @window = JS.global
    @document = @window[:document]
    @canvas = element("mural-canvas")
    @context = @canvas.getContext("2d", js(alpha: false))
    @user = { "name" => saved_name, "color" => COLORS[[6, 10, 12, 14].sample] }
    @client = Yrby::Wasm::Client.new(params: { id: element("pixel-studio")[:dataset][:documentId].to_s }, presence: { user: @user, cell: nil })
    @doc = @client.doc
    @scene, @pixels, @artist_pixels, @mural = %w[scene pixels artist_pixels mural].map { |name| @doc.map(name) }
    @undo = @doc.undo_manager(@pixels, origin: ORIGIN, capture_timeout: 60_000)
    @window[:__rubyPixel][:client] = @client.native
    @window[:__rubyPixel][:peer] = @client.native
    @selected = 7
    @tool = "brush"
    @grid = @cursor_visible = @queued = @brief_dirty = @invite_pending = false
    @cell = [32, 16]
    @active_pointer = @previous = nil
    @status = {}
    @invite_error = ""
    @paint_count = 0
    @rendered_colors = []
    build_palette
    bind_input
    bind_artist
    bind_misc
    @client.on_change { schedule_render; render_artist }
    @client.on_status { |status| update_status(status) }
    @undo.on_change { update_undo }
    element("your-name")[:value] = @user["name"]
    element("wasm-runtime")[:textContent] = "Ruby #{RUBY_VERSION} · #{RUBY_PLATFORM} · Yrs WASM"
    element("wasm-toggle-connection")[:disabled] = false
    @resize_observer = @window[:ResizeObserver].new(callback { schedule_render })
    @resize_observer.observe(element("canvas-wrap"))
    update_status(@client.status)
    @client.connect
    schedule_render
  end

  def element(id) = @document.getElementById(id)
  def js(value) = @window[:JSON].parse(JSON.generate(value))
  def true?(value) = value == JS::True
  def null?(value) = value == JS::Null || value == JS::Undefined
  # JS callbacks must return nil. Implicitly returning objects can attempt to
  # convert WASM32 Bignum peer IDs or recursively cross into a running runtime.
  def callback(&block) = ->(*args) { block.call(*args); nil }
  def listen(target, event, &block) = target.addEventListener(event, callback(&block))
  def later(delay, &block) = @window.setTimeout(callback(&block), delay)
  def cancel_timer(timer)
    @window.clearTimeout(timer) if timer
  end
  def then_promise(promise, success, failure = nil)
    promise.call(:then, callback(&success), callback { |error| failure&.call(error) })
  end

  def saved_name
    value = @window[:localStorage].getItem("pixel-bay-name")
    name = null?(value) ? "" : value.to_s.strip[0, 24]
    name.empty? ? "Ruby browser" : name
  rescue JS::Error
    "Ruby browser"
  end

  def build_palette
    @swatches = COLORS.each_with_index.map do |color, index|
      button = @document.createElement("button")
      button[:type] = "button"
      button[:className] = "swatch"
      button[:style][:backgroundColor] = color
      button[:style].setProperty("--indicator", [3, 4, 5, 8, 9, 11, 13, 15].include?(index) ? COLORS[0] : COLORS[5])
      button.setAttribute("aria-label", "#{NAMES[index]} (#{color})")
      button.setAttribute("title", NAMES[index])
      button.setAttribute("data-color", index.to_s)
      listen(button, "click") { select_color(index) }
      element("palette").appendChild(button)
      button
    end
    select_color(@selected)
  end

  def select_color(index)
    @selected = index
    @swatches.each_with_index { |button, i| button.setAttribute("aria-pressed", (i == index).to_s) }
    choose_tool("brush")
  end

  def choose_tool(tool)
    @tool = tool
    element("brush-tool").setAttribute("aria-pressed", (tool == "brush").to_s)
    element("eraser-tool").setAttribute("aria-pressed", (tool == "eraser").to_s)
    point_at(@cell) if @cursor_visible
  end

  def bind_input
    listen(@canvas, "pointerdown") do |event|
      next unless event[:button].to_i.zero? && true?(event[:isPrimary]) && @active_pointer.nil?
      cell = cell_from_pointer(event)
      next unless cell
      event.preventDefault
      @canvas.focus(js(preventScroll: true))
      @active_pointer = event[:pointerId].to_i
      @canvas.setPointerCapture(@active_pointer)
      @previous = cell
      @undo.stop_capturing
      point_at(cell)
      paint_cells([cell])
    end
    listen(@canvas, "pointermove") do |event|
      next unless true?(event[:isPrimary])
      next if @active_pointer && @active_pointer != event[:pointerId].to_i
      cell = cell_from_pointer(event)
      unless cell
        @previous = nil
        next
      end
      point_at(cell)
      if @active_pointer == event[:pointerId].to_i
        paint_cells(@previous ? line_between(@previous, cell) : [cell]) if @previous != cell
        @previous = cell
      end
    end
    %w[pointerup pointercancel lostpointercapture].each { |event| listen(@canvas, event) { |value| end_stroke(value) } }
    %w[pointerleave blur].each { |event| listen(@canvas, event) { hide_cursor if @active_pointer.nil? } }
    listen(@canvas, "focus") { point_at(@cell) }
    listen(@document, "keydown") { |event| keyboard(event) }
    listen(element("brush-tool"), "click") { choose_tool("brush") }
    listen(element("eraser-tool"), "click") { choose_tool("eraser") }
    listen(element("undo-stroke"), "click") { undo_stroke }
    listen(element("grid-tool"), "click") do
      @grid = !@grid
      @rendered_colors.clear
      element("grid-tool").setAttribute("aria-pressed", @grid.to_s)
      element("grid-tool").setAttribute("aria-label", @grid ? "Hide pixel grid" : "Show pixel grid")
      schedule_render
    end
  end

  def cell_from_pointer(event)
    rect = @canvas.getBoundingClientRect
    x, y = event[:clientX].to_f, event[:clientY].to_f
    return if x < rect[:left].to_f || x >= rect[:right].to_f || y < rect[:top].to_f || y >= rect[:bottom].to_f
    [((x - rect[:left].to_f) / rect[:width].to_f * WIDTH).floor,
     ((y - rect[:top].to_f) / rect[:height].to_f * HEIGHT).floor]
  end

  def end_stroke(event)
    return unless @active_pointer == event[:pointerId].to_i
    pointer = @active_pointer
    @active_pointer = @previous = nil
    @canvas.releasePointerCapture(pointer) if true?(@canvas.hasPointerCapture(pointer))
    @undo.stop_capturing
    hide_cursor if event[:pointerType].to_s == "touch"
  end

  def line_between(from, to)
    x, y = from
    end_x, end_y = to
    dx, dy = (end_x - x).abs, (end_y - y).abs
    sx, sy = x < end_x ? 1 : -1, y < end_y ? 1 : -1
    error = dx - dy
    cells = []
    loop do
      cells << [x, y]
      break if x == end_x && y == end_y
      twice = 2 * error
      if twice > -dy
        error -= dy
        x += sx
      end
      if twice < dx
        error += dx
        y += sy
      end
    end
    cells
  end

  def paint_cells(cells)
    @doc.transaction(origin: ORIGIN) do
      cells.each do |x, y|
        next unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)
        key = "#{x},#{y}"
        color = @tool == "eraser" ? valid_color(@scene[key]) : @selected
        next if @pixels.key?(key) && @pixels[key] == color
        @pixels[key] = color
        @paint_count += 1
      end
    end
    @canvas.setAttribute("data-ruby-paints", @paint_count.to_s)
  end

  def point_at(cell)
    @cell = cell
    @cursor_visible = true
    key = cell.join(",")
    presence = @client.presence || { "user" => @user }
    @client.presence = presence.merge("cell" => key) if presence["cell"] != key
    element("cell-status")[:textContent] = "%02d, %02d · %s" % [cell[0] + 1, cell[1] + 1, @tool == "eraser" ? "Restore scene" : NAMES[@selected]]
    render_cursors
  end

  def hide_cursor
    @cursor_visible = false
    @client.presence = (@client.presence || { "user" => @user }).merge("cell" => nil)
    render_cursors
  end

  def keyboard(event)
    return unless null?(event[:target].closest("input,textarea,[contenteditable=true]"))
    return if true?(event[:altKey])
    key = event[:key].to_s
    control = true?(event[:metaKey]) || true?(event[:ctrlKey])
    if control && key.downcase == "z"
      event.preventDefault
      true?(event[:shiftKey]) ? @undo.redo : undo_stroke
      update_undo
      return
    end
    return if control
    choose_tool("brush") if key.downcase == "b"
    choose_tool("eraser") if key.downcase == "e"
    return unless event[:target] == @canvas
    move = { "ArrowLeft" => [-1, 0], "ArrowRight" => [1, 0], "ArrowUp" => [0, -1], "ArrowDown" => [0, 1] }[key]
    if move
      event.preventDefault
      point_at([(@cell[0] + move[0]).clamp(0, WIDTH - 1), (@cell[1] + move[1]).clamp(0, HEIGHT - 1)])
    elsif key == " " || key == "Enter"
      event.preventDefault
      @undo.stop_capturing
      paint_cells([@cell])
      @undo.stop_capturing
    end
  end

  def undo_stroke
    @undo.stop_capturing
    @undo.undo
    update_undo
  end
  def update_undo = element("undo-stroke")[:disabled] = !@undo.can_undo?
  def valid_color(value) = value.is_a?(Integer) && value.between?(0, 15) ? value : 0

  def schedule_render
    return if @queued
    @queued = true
    @window.requestAnimationFrame(callback { @queued = false; render_canvas })
  end

  def render_canvas
    scene, pixels, artist = @scene.to_h, @pixels.to_h, @artist_pixels.to_h
    rect = @canvas.getBoundingClientRect
    dpr = @window[:devicePixelRatio].to_f
    dpr = 1 if dpr <= 0
    width, height = [(rect[:width].to_f * dpr).round, WIDTH].max, [(rect[:height].to_f * dpr).round, HEIGHT].max
    if @canvas[:width].to_i != width || @canvas[:height].to_i != height
      @canvas[:width], @canvas[:height] = width, height
      @rendered_colors.clear
    end
    @context[:imageSmoothingEnabled] = false
    HEIGHT.times do |y|
      WIDTH.times do |x|
        key = "#{x},#{y}"
        color = valid_color(pixels.fetch(key) { artist.fetch(key) { scene[key] } })
        index = y * WIDTH + x
        next if !@grid && @rendered_colors[index] == color
        @rendered_colors[index] = color
        left, top = (x * width.fdiv(WIDTH)).round, (y * height.fdiv(HEIGHT)).round
        @context[:fillStyle] = COLORS[color]
        @context.fillRect(left, top, ((x + 1) * width.fdiv(WIDTH)).round - left, ((y + 1) * height.fdiv(HEIGHT)).round - top)
      end
    end
    if @grid
      @context[:fillStyle] = "#f6eedb30"
      (1...WIDTH).each { |x| @context.fillRect((x * width.fdiv(WIDTH)).round, 0, 1, height) }
      (1...HEIGHT).each { |y| @context.fillRect(0, (y * height.fdiv(HEIGHT)).round, width, 1) }
    end
    @canvas.setAttribute("data-ruby-rendered", "true")
  end

  def update_status(status)
    @status = status
    connected = status["synced"]
    element("connection-status")[:textContent] = connected ? "Live · a shared canvas" : status["offline"] ? "Disconnected · keep drawing" : "Connecting to the studio…"
    element("connection-dot")[:className] = "live-dot#{connected ? '' : status['offline'] ? ' offline' : ' connecting'}"
    element("wasm-toggle-connection")[:textContent] = status["offline"] ? "Reconnect" : "Disconnect"
    count = status["pending"].to_i
    element("wasm-pending")[:textContent] = count.positive? ? "#{count} local updates waiting to sync" : "All local edits acknowledged"
    element("wasm-error")[:hidden] = status["error"].to_s.empty?
    element("wasm-error")[:textContent] = status["error"].to_s
    render_presence
    render_artist
  end

  def peers = @status.fetch("peers", [])
  def artist = peers.find { |peer| peer["artist"] && peer["user"].is_a?(Hash) }
  def safe_color(value) = value.to_s.match?(/\A#[0-9a-f]{6}\z/i) ? value : COLORS[6]

  def render_cursors
    layer = element("cursor-layer")
    layer.replaceChildren
    # Presence notifications are asynchronous, so use the current local state
    # for a responsive cursor before the provider's next status callback.
    states = peers.reject { |peer| peer["clientID"] == @status["clientID"] }
    states << (@client.presence || {}).merge("clientID" => @status["clientID"])
    states.each do |peer|
      next unless peer["user"].is_a?(Hash) && peer["cell"].to_s.match?(/\A\d+,\d+\z/)
      local = peer["clientID"] == @status["clientID"]
      next if local && !@cursor_visible
      x, y = peer["cell"].split(",").map(&:to_i)
      next unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)
      cursor = @document.createElement("span")
      cursor[:className] = "pixel-cursor#{local ? ' local' : ''}#{y < 3 ? ' near-top' : ''}#{x > 48 ? ' near-right' : ''}"
      cursor.setAttribute("data-name", peer["user"]["name"].to_s[0, 24])
      cursor[:style].setProperty("--cursor", safe_color(peer["user"]["color"]))
      cursor[:style][:left], cursor[:style][:top] = "#{100.0 * x / WIDTH}%", "#{100.0 * y / HEIGHT}%"
      layer.appendChild(cursor)
    end
  end

  def render_presence
    people = peers.select { |peer| peer["user"].is_a?(Hash) }.sort_by { |peer| [peer["clientID"] == @status["clientID"] ? 0 : 1, peer["clientID"]] }
    element("presence-count")[:textContent] = people.length == 1 ? "Just you" : "#{people.length} together"
    list = element("presence-list")
    list.replaceChildren
    people.each do |peer|
      row = @document.createElement("div")
      row[:className] = "presence-person"
      dot = @document.createElement("span")
      dot[:className] = "person-dot"
      dot[:style].setProperty("--person", safe_color(peer["user"]["color"]))
      name = @document.createElement("span")
      name[:className] = "person-name"
      name[:textContent] = peer["user"]["name"].to_s[0, 24]
      detail = @document.createElement("span")
      detail[:className] = "person-description"
      detail[:textContent] = peer["clientID"] == @status["clientID"] ? "you" : peer["artist"] ? "AI artist" : "painting pal"
      row.appendChild(dot)
      row.appendChild(name)
      row.appendChild(detail)
      list.appendChild(row)
    end
    render_cursors
  end

  def bind_misc
    listen(element("wasm-toggle-connection"), "click") { @status["offline"] ? @client.connect : @client.disconnect }
    listen(element("your-name"), "change") do |event|
      name = event[:target][:value].to_s.strip[0, 24]
      @user["name"] = name unless name.empty?
      event[:target][:value] = @user["name"]
      begin
        @window[:localStorage].setItem("pixel-bay-name", @user["name"])
      rescue JS::Error
        # Presence still works if storage is unavailable.
      end
      @client.presence = (@client.presence || {}).merge("user" => @user)
    end
    listen(element("share-mural"), "click") { share_room }
    listen(@window, "resize") { schedule_render }
    listen(@window, "pagehide") { flush_brief; @invite_controller&.abort }
  end

  def bind_artist
    listen(element("artist-brief"), "input") do
      @brief_dirty = true
      cancel_timer(@brief_timer)
      @brief_timer = later(350) { flush_brief }
    end
    listen(element("artist-brief"), "blur") { flush_brief }
    listen(element("invite-artist"), "submit") { |event| event.preventDefault; invite_artist }
    listen(element("remove-artist"), "click") { stop_artist }
  end

  def flush_brief
    cancel_timer(@brief_timer)
    return unless @brief_dirty
    @mural["brief"] = element("artist-brief")[:value].to_s[0, 240]
    @brief_dirty = false
  end

  def render_artist
    present = artist
    mural = @mural.to_h
    phase, stopped = mural["phase"], mural["enabled"] == false
    if present
      @invite_pending = false
      @invite_error = ""
      cancel_timer(@invite_timer)
    end
    element("artist-badge")[:textContent] = present ? "IN STUDIO" : @invite_pending ? "INVITED" : "OFFLINE"
    element("artist-badge")[:classList].toggle("online", !!present)
    element("invite-artist")[:hidden] = !!present
    element("invite-artist-button")[:disabled] = @invite_pending || !@status["synced"]
    element("invite-artist-button")[:textContent] = @invite_pending ? "Inviting Ruby…" : "✦ Invite Ruby to paint"
    element("remove-artist")[:hidden] = !present && !@invite_pending
    element("remove-artist")[:textContent] = present ? (stopped ? "Ruby is taking a break…" : "Let Ruby take a break") : "Cancel invitation"
    element("remove-artist")[:disabled] = !!present && stopped
    error = @invite_error.empty? && phase == "error" ? (mural["note"] || mural["status"] || "Ruby couldn't finish that turn. Try inviting Ruby again.").to_s : @invite_error
    element("artist-note")[:classList].toggle("error", !error.empty?)
    element("artist-phase-dot")[:className] = "live-dot#{!error.empty? || !present ? ' offline' : phase == 'thinking' ? ' connecting' : ''}"
    element("artist-phase")[:textContent] = if !error.empty?
      "Could not finish this turn"
    elsif present
      stopped ? "Wrapping up" : phase == "thinking" ? "Planning the next detail" : phase == "painting" ? "Painting" : "Studying the canvas"
    else
      @invite_pending ? "Waiting for Ruby to arrive" : "Ready when you are"
    end
    element("artist-commentary")[:textContent] = if !error.empty?
      error
    elsif present
      (mural["note"] || "Reading the canvas before adding new details.").to_s
    else
      @invite_pending ? "Ruby will appear here as soon as the artist joins." : "Invite Ruby to add details to the canvas."
    end
    turns = mural["turns"].to_i
    element("artist-meta")[:hidden] = !present && turns.zero?
    element("artist-meta")[:textContent] = "#{turns} creative #{turns == 1 ? 'turn' : 'turns'}#{mural['mode'] == 'test' ? ' · TEST MODE' : ''}"
    if !@brief_dirty && @document[:activeElement] != element("artist-brief")
      element("artist-brief")[:value] = mural["brief"].to_s[0, 240]
    end
  end

  def invitation_failed(message)
    @invite_pending = false
    @invite_error = message
    cancel_timer(@invite_timer)
    render_artist
  end

  def invite_artist
    return if @invite_pending || artist || !@status["synced"]
    flush_brief
    @invite_error = ""
    @invite_pending = true
    @invite_controller&.abort
    controller = @window[:AbortController].new
    @invite_controller = controller
    render_artist
    cancel_timer(@invite_timer)
    @invite_timer = later(15_000) do
      invitation_failed("Ruby hasn't arrived yet. You can try inviting again.") if !artist && @invite_controller == controller
    end
    token = @document.querySelector('meta[name="csrf-token"]')
    options = js(method: "POST", credentials: "same-origin", headers: {
      "Accept" => "text/event-stream", "X-CSRF-Token" => null?(token) ? "" : token[:content].to_s,
      "X-Pixel-Stop-Version" => @mural["stop_version"].to_s
    })
    options[:signal] = controller[:signal]
    then_promise(@window.fetch(element("invite-artist")[:action], options), ->(response) do
      unless true?(response[:ok])
        status = response[:status].to_i
        message = case status
        when 409 then "Ruby is already joining this room. Give it a moment, then try again if needed."
        when 503 then "Configure a model API key on the server to invite Ruby."
        else "Ruby couldn't join (#{status}). Please try again."
        end
        then_promise(response[:body].cancel, ->(*) {}) unless null?(response[:body])
        invitation_failed(message) if @invite_controller == controller
        next
      end
      if null?(response[:body])
        # Puma responds with 204 while its background artist is still joining.
        # Keep the invitation pending until presence arrives or the timer fires.
        invitation_finished(controller) unless @invite_pending
      else
        drain_invitation(response[:body].getReader, controller)
      end
    end, ->(error) { invitation_error(error, controller) })
  rescue JS::Error => error
    invitation_failed(error.message)
  end

  # Keep Falcon's streaming artist request alive. Promise continuations return
  # to Ruby on a fresh stack; no await or nested VM evaluation in DOM callbacks.
  def drain_invitation(reader, controller)
    then_promise(reader.read, ->(chunk) do
      if true?(chunk[:done])
        reader.releaseLock
        invitation_finished(controller)
      else
        drain_invitation(reader, controller)
      end
    end, ->(error) { reader.releaseLock; invitation_error(error, controller) })
  end

  def invitation_error(error, controller)
    return unless @invite_controller == controller
    invitation_failed(error[:message].to_s) unless error[:name].to_s == "AbortError"
    invitation_finished(controller)
  end

  def invitation_finished(controller)
    return unless @invite_controller == controller
    invitation_failed("Ruby left before joining the studio. Try inviting again.") if @invite_pending && !artist
    @invite_controller = nil unless @invite_pending
    render_artist
  end

  def stop_artist
    bytes = @window[:crypto].getRandomValues(@window[:Uint8Array].new(16))
    stop_version = 16.times.map { |i| "%02x" % bytes[i].to_i }.join
    @doc.transaction do
      @mural["stop_version"] = stop_version
      @mural["enabled"] = false
    end
    @invite_controller&.abort
    @invite_controller = nil
    cancel_timer(@invite_timer)
    @invite_pending = false
    @invite_error = ""
    render_artist
  end

  def share_room
    then_promise(@window[:navigator][:clipboard].writeText(@window[:location][:href]),
      ->(*) { toast("Room link copied. Bring a friend to the bay.") },
      ->(*) { share_fallback })
  rescue JS::Error
    share_fallback
  end

  def share_fallback = @window.prompt("Copy this link to invite a friend:", @window[:location][:href])

  def toast(message)
    element("studio-toast")[:textContent] = message
    element("studio-toast")[:hidden] = false
    cancel_timer(@toast_timer)
    @toast_timer = later(4000) { element("studio-toast")[:hidden] = true }
  end
end

PIXEL_BROWSER = PixelBrowser.new
