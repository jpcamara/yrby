# frozen_string_literal: true

# Pixel Bay's studio in Ruby, compiled ahead of time to WebAssembly by Spinel.
# Ruby owns the studio: painting, tools, strokes, keyboard, undo, rendering,
# cursors, presence and the artist panel. It also owns the document, through
# yrs linked into the same module (yrs.rb), and the sync protocol (sync.rb).
# host.js owns the browser surface: DOM events, the canvas, fetch and the
# ActionCable socket. Every crossing is one of the Host functions below.
require "json"
require_relative "yrs"
require_relative "sync"

module Host
  ffi_func :host_log, [:str], :void

  # Events. JavaScript calls Pixel.dispatch(code) for a listener, timer or
  # client callback; the ev_* functions read the event being dispatched.
  ffi_func :host_listen, [:str, :str, :int], :void
  ffi_func :host_timeout, [:int, :int], :int
  ffi_func :host_clear_timeout, [:int], :void
  ffi_func :host_frame, [:int], :void
  ffi_func :host_ev_num, [:str], :double
  ffi_func :host_ev_str, [:str], :str
  ffi_func :host_ev_bool, [:str], :bool
  ffi_func :host_ev_prevent, [], :void

  # The DOM, addressed by element id.
  ffi_func :host_create, [:str, :str, :str], :void
  ffi_func :host_clear, [:str], :void
  ffi_func :host_text, [:str, :str], :void
  ffi_func :host_prop, [:str, :str, :str], :void
  ffi_func :host_flag, [:str, :str, :bool], :void
  ffi_func :host_attr, [:str, :str, :str], :void
  ffi_func :host_class, [:str, :str, :bool], :void
  ffi_func :host_style, [:str, :str, :str], :void
  ffi_func :host_get, [:str, :str], :str
  ffi_func :host_rect, [:str, :str], :double
  ffi_func :host_active, [], :str
  ffi_func :host_focus, [:str], :void
  ffi_func :host_capture, [:str, :int, :bool], :void

  # The canvas and the window.
  ffi_func :host_fill, [:str, :int, :int, :int, :int], :void
  ffi_func :host_dpr, [], :double
  ffi_func :host_storage_get, [:str], :str
  ffi_func :host_storage_set, [:str, :str], :void
  ffi_func :host_share, [], :void
  ffi_func :host_invite, [:str, :str, :int], :void
  ffi_func :host_abort, [:int], :void

  ffi_func :host_now, [], :double
  ffi_func :host_random, [], :int

  # The ActionCable subscription. Its callbacks arrive as CABLE_* dispatches.
  ffi_func :host_cable_open, [:str, :str], :void
  ffi_func :host_cable_send, [:str, :int], :void
  ffi_func :host_cable_close, [], :void

  # Answers window.__spinelPixel.client, the page's inspection hook.
  ffi_func :host_reply, [:str], :void
end

class Studio
  WIDTH = 64
  HEIGHT = 32
  COLORS = %w[#1d2038 #38415d #697a91 #b4c3ce #f6eedb #ffffff #c85b50 #f27c63 #f6bb6a #ffe7a0 #447a70 #78b38b #36699b #66a4cc #9b78aa #d69bbd].freeze
  NAMES = ["Midnight", "Slate", "Fog", "Silver", "Cream", "White", "Bridge red", "Coral", "Apricot", "Sunshine", "Evergreen", "Sage", "Ocean", "Sky", "Lavender", "Rose"].freeze
  DARK_INDICATOR = [3, 4, 5, 8, 9, 11, 13, 15].freeze
  ORIGIN = "pixel-bay-human"
  LOCAL = "yrby-wasm-local"
  CANVAS = "mural-canvas"

  # Dispatch codes. A swatch click is SWATCH + its color index.
  POINTER_DOWN = 1
  POINTER_MOVE = 2
  POINTER_END = 3
  POINTER_LEAVE = 4
  CANVAS_FOCUS = 5
  KEYDOWN = 6
  BRUSH = 7
  ERASER = 8
  UNDO = 9
  GRID = 10
  TOGGLE_CONNECTION = 11
  NAME_CHANGE = 12
  SHARE = 13
  RESIZE = 14
  PAGEHIDE = 15
  BRIEF_INPUT = 16
  BRIEF_BLUR = 17
  INVITE = 18
  STOP_ARTIST = 19
  CABLE_CONNECTED = 20
  CABLE_DISCONNECTED = 21
  CABLE_REJECTED = 22
  FRAME = 23
  BRIEF_TIMER = 24
  INVITE_TIMER = 25
  TOAST_TIMER = 26
  INVITE_RESPONSE = 27
  INVITE_DONE = 28
  INVITE_ERROR = 29
  SHARED = 30
  CABLE_MESSAGE = 31
  RESEND_TIMER = 32
  RENEW_TIMER = 33
  PAGESHOW = 34
  INSPECT_STATUS = 35
  INSPECT_MAP = 36
  SWATCH = 100
  RENEW_MS = 10_000

  def initialize
    @selected = 7
    @tool = "brush"
    @grid = false
    @cursor_visible = false
    @queued = false
    @brief_dirty = false
    @invite_pending = false
    @cell_x = 32
    @cell_y = 16
    @active_pointer = -1
    @previous_x = -1
    @previous_y = -1
    @peers = []
    @client_id = ""
    @synced = false
    @offline = false
    @invite_error = ""
    @invite_token = 0
    @next_token = 0
    @brief_timer = 0
    @invite_timer = 0
    @toast_timer = 0
    @paint_count = 0
    @rendered = Array.new(WIDTH * HEIGHT, -1)
    @name = saved_name
    @color = COLORS[[6, 10, 12, 14].sample]
    @presence_cell = ""
    @can_undo = true
    @resume = false
    @document = Document.new(Host.host_random)
    @document.track_undo("pixels", ORIGIN, 60_000)
    @sync = Sync.new(@document, "DocumentChannel", Host.host_get("pixel-studio", "dataset.documentId"),
      JSON.generate(presence_state))
  end

  def start
    @sync.connect
    Host.host_timeout(RENEW_MS, RENEW_TIMER)
    build_palette
    bind
    Host.host_prop("your-name", "value", @name)
    Host.host_text("wasm-runtime", "#{RUBY_ENGINE} #{RUBY_VERSION} · compiled Ruby · wasm32-wasi · yrs linked in")
    Host.host_flag("wasm-toggle-connection", "disabled", false)
    update_status
    schedule_render
  end

  # After each dispatch: send local edits, then redraw what changed.
  def settle
    @sync.flush
    doc_changed if @document.changed?
    update_status if @sync.status_changed?
    update_undo
  end

  def handle(code)
    if code >= SWATCH
      select_color(code - SWATCH)
      return
    end
    case code
    when POINTER_DOWN then pointer_down
    when POINTER_MOVE then pointer_move
    when POINTER_END then end_stroke
    when POINTER_LEAVE then hide_cursor if @active_pointer < 0
    when CANVAS_FOCUS then point_at(@cell_x, @cell_y)
    when KEYDOWN then keyboard
    when BRUSH then choose_tool("brush")
    when ERASER then choose_tool("eraser")
    when UNDO then undo_stroke
    when GRID then toggle_grid
    when TOGGLE_CONNECTION then @sync.offline? ? @sync.connect : @sync.disconnect
    when NAME_CHANGE then change_name
    when SHARE then Host.host_share
    when SHARED then toast("Room link copied. Bring a friend to the bay.")
    when RESIZE then schedule_render
    when PAGEHIDE then pagehide
    when PAGESHOW then @sync.connect if @resume && Host.host_ev_bool("persisted")
    when BRIEF_INPUT then brief_input
    when BRIEF_BLUR, BRIEF_TIMER then flush_brief
    when INVITE then invite_artist
    when STOP_ARTIST then stop_artist
    when CABLE_CONNECTED then @sync.connected
    when CABLE_DISCONNECTED then @sync.disconnected
    when CABLE_REJECTED then @sync.rejected
    when CABLE_MESSAGE then receive(Host.host_ev_str("json"))
    when RESEND_TIMER then @sync.resend
    when RENEW_TIMER then renew
    when INSPECT_STATUS then Host.host_reply(@sync.status_json)
    when INSPECT_MAP then Host.host_reply(@document.json(Host.host_ev_str("name")))
    when FRAME then frame
    when INVITE_TIMER then invite_timed_out
    when TOAST_TIMER then Host.host_flag("studio-toast", "hidden", true)
    when INVITE_RESPONSE then invite_response
    when INVITE_DONE then invitation_finished(Host.host_ev_num("token").to_i)
    when INVITE_ERROR then invitation_error
    end
  end

  # Palette and tools

  def build_palette
    COLORS.each_with_index do |color, index|
      id = "swatch-#{index}"
      Host.host_create("palette", "button", id)
      Host.host_prop(id, "type", "button")
      Host.host_prop(id, "className", "swatch")
      Host.host_style(id, "backgroundColor", color)
      Host.host_style(id, "--indicator", DARK_INDICATOR.include?(index) ? COLORS[0] : COLORS[5])
      Host.host_attr(id, "aria-label", "#{NAMES[index]} (#{color})")
      Host.host_attr(id, "title", NAMES[index])
      Host.host_attr(id, "data-color", index.to_s)
      Host.host_listen(id, "click", SWATCH + index)
    end
    select_color(@selected)
  end

  def select_color(index)
    @selected = index
    COLORS.each_index { |i| Host.host_attr("swatch-#{i}", "aria-pressed", (i == index).to_s) }
    choose_tool("brush")
  end

  def choose_tool(tool)
    @tool = tool
    Host.host_attr("brush-tool", "aria-pressed", (tool == "brush").to_s)
    Host.host_attr("eraser-tool", "aria-pressed", (tool == "eraser").to_s)
    point_at(@cell_x, @cell_y) if @cursor_visible
  end

  def toggle_grid
    @grid = !@grid
    @rendered.fill(-1)
    Host.host_attr("grid-tool", "aria-pressed", @grid.to_s)
    Host.host_attr("grid-tool", "aria-label", @grid ? "Hide pixel grid" : "Show pixel grid")
    schedule_render
  end

  def bind
    Host.host_listen(CANVAS, "pointerdown", POINTER_DOWN)
    Host.host_listen(CANVAS, "pointermove", POINTER_MOVE)
    Host.host_listen(CANVAS, "pointerup", POINTER_END)
    Host.host_listen(CANVAS, "pointercancel", POINTER_END)
    Host.host_listen(CANVAS, "lostpointercapture", POINTER_END)
    Host.host_listen(CANVAS, "pointerleave", POINTER_LEAVE)
    Host.host_listen(CANVAS, "blur", POINTER_LEAVE)
    Host.host_listen(CANVAS, "focus", CANVAS_FOCUS)
    Host.host_listen("document", "keydown", KEYDOWN)
    Host.host_listen("brush-tool", "click", BRUSH)
    Host.host_listen("eraser-tool", "click", ERASER)
    Host.host_listen("undo-stroke", "click", UNDO)
    Host.host_listen("grid-tool", "click", GRID)
    Host.host_listen("wasm-toggle-connection", "click", TOGGLE_CONNECTION)
    Host.host_listen("your-name", "change", NAME_CHANGE)
    Host.host_listen("share-mural", "click", SHARE)
    Host.host_listen("window", "resize", RESIZE)
    Host.host_listen("canvas-wrap", "resize", RESIZE)
    Host.host_listen("window", "pagehide", PAGEHIDE)
    Host.host_listen("window", "pageshow", PAGESHOW)
    Host.host_listen("artist-brief", "input", BRIEF_INPUT)
    Host.host_listen("artist-brief", "blur", BRIEF_BLUR)
    Host.host_listen("invite-artist", "submit", INVITE)
    Host.host_listen("remove-artist", "click", STOP_ARTIST)
  end

  # Pointer and keyboard painting

  def pointer_down
    return unless Host.host_ev_num("button").to_i == 0 && Host.host_ev_bool("isPrimary") && @active_pointer < 0
    return unless cell_from_pointer
    Host.host_ev_prevent
    Host.host_focus(CANVAS)
    @active_pointer = Host.host_ev_num("pointerId").to_i
    Host.host_capture(CANVAS, @active_pointer, true)
    @previous_x = @hit_x
    @previous_y = @hit_y
    @document.stop_capturing
    point_at(@hit_x, @hit_y)
    paint_cells([[@hit_x, @hit_y]])
  end

  def pointer_move
    return unless Host.host_ev_bool("isPrimary")
    pointer = Host.host_ev_num("pointerId").to_i
    return if @active_pointer >= 0 && @active_pointer != pointer
    unless cell_from_pointer
      @previous_x = -1
      return
    end
    point_at(@hit_x, @hit_y)
    return unless @active_pointer == pointer
    if @previous_x < 0
      paint_cells([[@hit_x, @hit_y]])
    elsif @previous_x != @hit_x || @previous_y != @hit_y
      paint_cells(line_between(@previous_x, @previous_y, @hit_x, @hit_y))
    end
    @previous_x = @hit_x
    @previous_y = @hit_y
  end

  # Sets @hit_x/@hit_y to the cell under the pointer; false when it is outside.
  def cell_from_pointer
    x = Host.host_ev_num("clientX")
    y = Host.host_ev_num("clientY")
    left = Host.host_rect(CANVAS, "left")
    top = Host.host_rect(CANVAS, "top")
    width = Host.host_rect(CANVAS, "width")
    height = Host.host_rect(CANVAS, "height")
    return false if x < left || x >= left + width || y < top || y >= top + height
    @hit_x = ((x - left) / width * WIDTH).floor
    @hit_y = ((y - top) / height * HEIGHT).floor
    true
  end

  def end_stroke
    pointer = Host.host_ev_num("pointerId").to_i
    return unless @active_pointer >= 0 && @active_pointer == pointer
    @active_pointer = -1
    @previous_x = -1
    Host.host_capture(CANVAS, pointer, false)
    @document.stop_capturing
    hide_cursor if Host.host_ev_str("pointerType") == "touch"
  end

  def line_between(x, y, end_x, end_y)
    dx = (end_x - x).abs
    dy = (end_y - y).abs
    sx = x < end_x ? 1 : -1
    sy = y < end_y ? 1 : -1
    error = dx - dy
    cells = []
    while true
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
    @document.write(ORIGIN) do
      cells.each do |cell|
        x = cell[0]
        y = cell[1]
        next unless x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT
        key = "#{x},#{y}"
        color = @tool == "eraser" ? palette_index(@document.get_int("scene", key, 0)) : @selected
        next if @document.get_int("pixels", key, -1) == color
        @document.set_int("pixels", key, color)
        @paint_count += 1
      end
    end
    Host.host_attr(CANVAS, "data-ruby-paints", @paint_count.to_s)
  end

  def point_at(x, y)
    @cell_x = x
    @cell_y = y
    @cursor_visible = true
    publish_cell("#{x},#{y}")
    tool = @tool == "eraser" ? "Restore scene" : NAMES[@selected]
    Host.host_text("cell-status", "#{pad(x + 1)}, #{pad(y + 1)} · #{tool}")
    render_cursors
  end

  def pad(number) = number < 10 ? "0#{number}" : number.to_s

  def hide_cursor
    @cursor_visible = false
    publish_cell("")
    render_cursors
  end

  def keyboard
    return if Host.host_ev_bool("inEditor") || Host.host_ev_bool("altKey")
    key = Host.host_ev_str("key")
    control = Host.host_ev_bool("metaKey") || Host.host_ev_bool("ctrlKey")
    if control && key.downcase == "z"
      Host.host_ev_prevent
      if Host.host_ev_bool("shiftKey")
        @document.redo
      else
        undo_stroke
      end
      update_undo
      return
    end
    return if control
    choose_tool("brush") if key.downcase == "b"
    choose_tool("eraser") if key.downcase == "e"
    return unless Host.host_ev_bool("onCanvas")
    dx = 0
    dy = 0
    if key == "ArrowLeft"
      dx = -1
    elsif key == "ArrowRight"
      dx = 1
    elsif key == "ArrowUp"
      dy = -1
    elsif key == "ArrowDown"
      dy = 1
    end
    if dx != 0 || dy != 0
      Host.host_ev_prevent
      point_at((@cell_x + dx).clamp(0, WIDTH - 1), (@cell_y + dy).clamp(0, HEIGHT - 1))
    elsif key == " " || key == "Enter"
      Host.host_ev_prevent
      @document.stop_capturing
      paint_cells([[@cell_x, @cell_y]])
      @document.stop_capturing
    end
  end

  def undo_stroke
    @document.stop_capturing
    @document.undo
    update_undo
  end

  def update_undo
    can_undo = @document.can_undo?
    return if can_undo == @can_undo
    @can_undo = can_undo
    Host.host_flag("undo-stroke", "disabled", !can_undo)
  end

  # A shared map value as a palette index; anything else is Midnight.
  def palette_index(value) = value >= 0 && value <= 15 ? value : 0

  # Rendering

  def doc_changed
    schedule_render
    render_artist
  end

  def schedule_render
    return if @queued
    @queued = true
    Host.host_frame(FRAME)
  end

  def frame
    @queued = false
    render_canvas
  end

  def layer(name)
    colors = Array.new(WIDTH * HEIGHT, -1)
    @document.each_int(name) do |key, value|
      next unless value >= 0 && value <= 15 && key.match?(/\A\d+,\d+\z/)
      parts = key.split(",")
      x = parts[0].to_i
      y = parts[1].to_i
      colors[y * WIDTH + x] = value if x < WIDTH && y < HEIGHT
    end
    colors
  end

  def render_canvas
    scene = layer("scene")
    pixels = layer("pixels")
    artist = layer("artist_pixels")
    dpr = Host.host_dpr
    dpr = 1.0 if dpr <= 0
    width = [(Host.host_rect(CANVAS, "width") * dpr).round, WIDTH].max
    height = [(Host.host_rect(CANVAS, "height") * dpr).round, HEIGHT].max
    if Host.host_get(CANVAS, "width").to_i != width || Host.host_get(CANVAS, "height").to_i != height
      Host.host_prop(CANVAS, "width", width.to_s)
      Host.host_prop(CANVAS, "height", height.to_s)
      @rendered.fill(-1)
    end
    cell_w = width.to_f / WIDTH
    cell_h = height.to_f / HEIGHT
    HEIGHT.times do |y|
      WIDTH.times do |x|
        index = y * WIDTH + x
        color = pixels[index]
        color = artist[index] if color < 0
        color = scene[index] if color < 0
        color = 0 if color < 0
        next if !@grid && @rendered[index] == color
        @rendered[index] = color
        left = (x * cell_w).round
        top = (y * cell_h).round
        Host.host_fill(COLORS[color], left, top, ((x + 1) * cell_w).round - left, ((y + 1) * cell_h).round - top)
      end
    end
    if @grid
      (1...WIDTH).each { |x| Host.host_fill("#f6eedb30", (x * cell_w).round, 0, 1, height) }
      (1...HEIGHT).each { |y| Host.host_fill("#f6eedb30", 0, (y * cell_h).round, width, 1) }
    end
    Host.host_attr(CANVAS, "data-ruby-rendered", "true")
  end

  # Connection, presence and cursors

  def receive(message)
    @sync.received(message)
  rescue => error
    @sync.fail(error.message)
  end

  def renew
    @sync.renew
    Host.host_timeout(RENEW_MS, RENEW_TIMER)
  end

  def update_status
    @synced = @sync.synced?
    @offline = @sync.offline?
    @client_id = @sync.client_id.to_s
    @peers = @sync.peers.select { |peer| peer["user"].is_a?(Hash) }
    connection = if @synced
      "Live · a shared canvas"
    elsif @offline
      "Disconnected · keep drawing"
    else
      "Connecting to the studio…"
    end
    Host.host_text("connection-status", connection)
    Host.host_prop("connection-dot", "className", @synced ? "live-dot" : @offline ? "live-dot offline" : "live-dot connecting")
    Host.host_text("wasm-toggle-connection", @offline ? "Reconnect" : "Disconnect")
    pending = @sync.pending
    Host.host_text("wasm-pending", pending > 0 ? "#{pending} local updates waiting to sync" : "All local edits acknowledged")
    error = @sync.error
    Host.host_flag("wasm-error", "hidden", error.empty?)
    Host.host_text("wasm-error", error)
    render_presence
    render_artist
  end

  def presence_state
    user = { "name" => @name, "color" => @color }
    return { "user" => user, "cell" => nil } if @presence_cell.empty?
    { "user" => user, "cell" => @presence_cell }
  end

  def publish_cell(cell)
    return if @presence_cell == cell
    @presence_cell = cell
    @sync.presence = JSON.generate(presence_state)
  end

  def local?(peer) = peer["clientID"].to_s == @client_id
  def artist_present? = @peers.any? { |peer| peer["artist"] == true }
  def safe_color(value) = value.to_s.match?(/\A#[0-9a-fA-F]{6}\z/) ? value.to_s : COLORS[6]
  def name_of(peer) = peer["user"]["name"].to_s[0, 24]
  def color_of_peer(peer) = safe_color(peer["user"]["color"])

  def render_cursors
    Host.host_clear("cursor-layer")
    count = 0
    @peers.each do |peer|
      next if local?(peer)
      cell = peer["cell"].to_s
      next unless cell.match?(/\A\d+,\d+\z/)
      count += 1
      cursor(count, cell, name_of(peer), color_of_peer(peer), false)
    end
    # Presence notifications arrive later, so draw the local cursor from the
    # state this tab just published.
    if @cursor_visible && !@presence_cell.empty?
      cursor(count + 1, @presence_cell, @name[0, 24], @color, true)
    end
  end

  def cursor(index, cell, name, color, local)
    parts = cell.split(",")
    x = parts[0].to_i
    y = parts[1].to_i
    return unless x < WIDTH && y < HEIGHT
    id = "cursor-#{index}"
    Host.host_create("cursor-layer", "span", id)
    classes = "pixel-cursor"
    classes += " local" if local
    classes += " near-top" if y < 3
    classes += " near-right" if x > 48
    Host.host_prop(id, "className", classes)
    Host.host_attr(id, "data-name", name)
    Host.host_style(id, "--cursor", color)
    Host.host_style(id, "left", "#{100.0 * x / WIDTH}%")
    Host.host_style(id, "top", "#{100.0 * y / HEIGHT}%")
  end

  def render_presence
    people = @peers.select { |peer| local?(peer) } + @peers.reject { |peer| local?(peer) }.sort_by { |peer| peer["clientID"].to_s.rjust(10, "0") }
    Host.host_text("presence-count", people.size == 1 ? "Just you" : "#{people.size} together")
    Host.host_clear("presence-list")
    people.each_with_index do |peer, index|
      row = "person-#{index}"
      Host.host_create("presence-list", "div", row)
      Host.host_prop(row, "className", "presence-person")
      Host.host_create(row, "span", "#{row}-dot")
      Host.host_prop("#{row}-dot", "className", "person-dot")
      Host.host_style("#{row}-dot", "--person", color_of_peer(peer))
      Host.host_create(row, "span", "#{row}-name")
      Host.host_prop("#{row}-name", "className", "person-name")
      Host.host_text("#{row}-name", name_of(peer))
      Host.host_create(row, "span", "#{row}-detail")
      Host.host_prop("#{row}-detail", "className", "person-description")
      detail = if local?(peer)
        "you"
      elsif peer["artist"] == true
        "AI artist"
      else
        "painting pal"
      end
      Host.host_text("#{row}-detail", detail)
    end
    render_cursors
  end

  def saved_name
    name = Host.host_storage_get("pixel-bay-name").strip[0, 24]
    name.empty? ? "Ruby browser" : name
  end

  def change_name
    name = Host.host_get("your-name", "value").strip[0, 24]
    @name = name unless name.empty?
    Host.host_prop("your-name", "value", @name)
    Host.host_storage_set("pixel-bay-name", @name)
    @sync.presence = JSON.generate(presence_state)
    render_cursors
  end

  # Leave the room on the way out; a page restored from the back-forward cache
  # rejoins it.
  def pagehide
    flush_brief
    Host.host_abort(@invite_token) if @invite_token > 0
    @resume = !@sync.offline?
    @sync.disconnect
  end

  # The AI artist

  def brief_input
    @brief_dirty = true
    Host.host_clear_timeout(@brief_timer) if @brief_timer > 0
    @brief_timer = Host.host_timeout(350, BRIEF_TIMER)
  end

  def flush_brief
    Host.host_clear_timeout(@brief_timer) if @brief_timer > 0
    @brief_timer = 0
    return unless @brief_dirty
    brief = Host.host_get("artist-brief", "value")[0, 240]
    @document.write(LOCAL) { @document.set_string("mural", "brief", brief) }
    @brief_dirty = false
  end

  def mural_text(mural, key)
    value = mural[key]
    value.is_a?(String) ? value : ""
  end

  def render_artist
    present = artist_present?
    mural = JSON.parse(@document.json("mural"))
    phase = mural_text(mural, "phase")
    stopped = mural["enabled"] == false
    if present
      @invite_pending = false
      @invite_error = ""
      cancel_invite_timer
    end
    Host.host_text("artist-badge", present ? "IN STUDIO" : @invite_pending ? "INVITED" : "OFFLINE")
    Host.host_class("artist-badge", "online", present)
    Host.host_flag("invite-artist", "hidden", present)
    Host.host_flag("invite-artist-button", "disabled", @invite_pending || !@synced)
    Host.host_text("invite-artist-button", @invite_pending ? "Inviting Ruby…" : "✦ Invite Ruby to paint")
    Host.host_flag("remove-artist", "hidden", !present && !@invite_pending)
    Host.host_text("remove-artist", present ? (stopped ? "Ruby is taking a break…" : "Let Ruby take a break") : "Cancel invitation")
    Host.host_flag("remove-artist", "disabled", present && stopped)
    error = @invite_error
    if error.empty? && phase == "error"
      error = mural_text(mural, "note")
      error = mural_text(mural, "status") if error.empty?
      error = "Ruby couldn't finish that turn. Try inviting Ruby again." if error.empty?
    end
    failed = !error.empty?
    Host.host_class("artist-note", "error", failed)
    dot = if failed || !present
      "live-dot offline"
    elsif phase == "thinking"
      "live-dot connecting"
    else
      "live-dot"
    end
    Host.host_prop("artist-phase-dot", "className", dot)
    Host.host_text("artist-phase", artist_phase(failed, present, stopped, phase))
    note = mural_text(mural, "note")
    commentary = if failed
      error
    elsif present
      note.empty? ? "Reading the canvas before adding new details." : note
    elsif @invite_pending
      "Ruby will appear here as soon as the artist joins."
    else
      "Invite Ruby to add details to the canvas."
    end
    Host.host_text("artist-commentary", commentary)
    turns = mural["turns"].is_a?(Integer) ? mural["turns"].to_s.to_i : 0
    Host.host_flag("artist-meta", "hidden", !present && turns == 0)
    test_mode = mural_text(mural, "mode") == "test" ? " · TEST MODE" : ""
    Host.host_text("artist-meta", "#{turns} creative #{turns == 1 ? 'turn' : 'turns'}#{test_mode}")
    if !@brief_dirty && Host.host_active != "artist-brief"
      Host.host_prop("artist-brief", "value", mural_text(mural, "brief")[0, 240])
    end
  end

  def artist_phase(failed, present, stopped, phase)
    return "Could not finish this turn" if failed
    return(@invite_pending ? "Waiting for Ruby to arrive" : "Ready when you are") unless present
    return "Wrapping up" if stopped
    return "Planning the next detail" if phase == "thinking"
    return "Painting" if phase == "painting"
    "Studying the canvas"
  end

  def cancel_invite_timer
    Host.host_clear_timeout(@invite_timer) if @invite_timer > 0
    @invite_timer = 0
  end

  def invitation_failed(message)
    @invite_pending = false
    @invite_error = message
    cancel_invite_timer
    render_artist
  end

  def invite_artist
    Host.host_ev_prevent
    return if @invite_pending || artist_present? || !@synced
    flush_brief
    @invite_error = ""
    @invite_pending = true
    Host.host_abort(@invite_token) if @invite_token > 0
    @next_token += 1
    @invite_token = @next_token
    render_artist
    cancel_invite_timer
    @invite_timer = Host.host_timeout(15_000, INVITE_TIMER)
    stop_version = JSON.parse(@document.json("mural"))["stop_version"]
    Host.host_invite(Host.host_get("invite-artist", "action"), stop_version.is_a?(String) ? stop_version : "", @invite_token)
  end

  def invite_timed_out
    @invite_timer = 0
    invitation_failed("Ruby hasn't arrived yet. You can try inviting again.") if @invite_pending && !artist_present?
  end

  def invite_response
    token = Host.host_ev_num("token").to_i
    return unless token == @invite_token
    status = Host.host_ev_num("status").to_i
    if Host.host_ev_bool("ok")
      # Puma answers 204 while its background artist is still joining. Stay
      # invited until presence arrives or the timer fires.
      invitation_finished(token) if !Host.host_ev_bool("body") && !@invite_pending
      return
    end
    message = if status == 409
      "Ruby is already joining this room. Give it a moment, then try again if needed."
    elsif status == 503
      "Configure a model API key on the server to invite Ruby."
    else
      "Ruby couldn't join (#{status}). Please try again."
    end
    invitation_failed(message)
  end

  def invitation_error
    token = Host.host_ev_num("token").to_i
    return unless token == @invite_token
    invitation_failed(Host.host_ev_str("message")) unless Host.host_ev_str("name") == "AbortError"
    invitation_finished(token)
  end

  def invitation_finished(token)
    return unless token == @invite_token
    invitation_failed("Ruby left before joining the studio. Try inviting again.") if @invite_pending && !artist_present?
    @invite_token = 0 unless @invite_pending
    render_artist
  end

  def stop_artist
    hex = "0123456789abcdef"
    stop_version = ""
    32.times { stop_version += hex[rand(16)] }
    @document.write(LOCAL) do
      @document.set_string("mural", "stop_version", stop_version)
      @document.set_bool("mural", "enabled", false)
    end
    Host.host_abort(@invite_token) if @invite_token > 0
    @invite_token = 0
    cancel_invite_timer
    @invite_pending = false
    @invite_error = ""
    render_artist
  end

  def toast(message)
    Host.host_text("studio-toast", message)
    Host.host_flag("studio-toast", "hidden", false)
    Host.host_clear_timeout(@toast_timer) if @toast_timer > 0
    @toast_timer = Host.host_timeout(4000, TOAST_TIMER)
  end
end

module Pixel
  def self.studio = ($studio ||= Studio.new)

  def self.start
    studio.start
    studio.settle
    0
  end

  def self.dispatch(code)
    studio.handle(code)
    studio.settle unless code == Studio::INSPECT_STATUS || code == Studio::INSPECT_MAP
    0
  end
end
