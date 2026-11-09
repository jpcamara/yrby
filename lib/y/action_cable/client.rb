# frozen_string_literal: true

begin
  require "async"
  require "async/http/endpoint"
  require "async/websocket/client"
rescue LoadError => e
  raise LoadError, "Y::ActionCable::Client needs the async-websocket gem. Add it to your Gemfile. (#{e.message})"
end
require "json"
require "logger"
require "y/action_cable/client/session"

# y/collaborator loads this file too, so one warning covers both.
warn "yrby: Y::ActionCable::Client and Y::Collaborator are experimental and may change in a minor release. " \
     "Warning[:experimental] = false turns this off.", category: :experimental

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  # Joins a document the way a browser does: over the
  # cable's websocket, as a client of the document channel. It holds a
  # Y::Doc, follows the document, and sends its own edits and presence
  # through the channel, so the server records, acks, and distributes them
  # like anyone else's. The process touches neither the pubsub nor the
  # store. It needs the cable URL and the same way in a browser has: the
  # channel's name and params, such as a grant the app minted with
  # record.collaborative_document(name).grant.
  #
  #   client = Y::ActionCable::Client.new("wss://example.com/cable",
  #                                       params: { grant: post.collaborative_document(:body).grant, name: "body" })
  #   client.on_update { |update, doc, changed| ... } # changed: block ordinals touched
  #   client.subscribe # connects and returns once the document has arrived
  #   client.presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
  #   client.edit { |doc| Y::Lexxy.append_paragraph(doc, "hello") }
  #   client.unsubscribe # waits for acks, clears presence, and closes
  #
  # The client sends the URL's own origin as its Origin, which Action Cable
  # accepts. `headers:` go on the websocket request for anything more: an
  # Origin when the cable is reached at another address than the site's, or
  # a token for an ApplicationCable::Connection that requires a login, since
  # the process has no cookie.
  #
  # The client runs as a task of the reactor `subscribe` is called from
  # when there is one (Falcon, or an Async block), and in a thread of its
  # own otherwise (Puma, a script). Callbacks run on that reactor; keep
  # them short. edit and presence= may be called from any thread or fiber.
  #
  # Delivery is at least once, as in the JS provider: every update carries
  # an id and is kept until the server acks it, resent on a timer and after
  # a reconnect. A dropped socket reconnects with backoff. A rejected
  # subscription, or a server asking not to reconnect, ends the client.
  class Client
    PROTOCOL = "actioncable-v1-json"
    RESEND = 1     # seconds between retransmits of unacked updates
    STALE = 15     # seconds without a message before the socket is given up; the server pings every 3
    RENEW = 15     # seconds between presence renewals; peers drop a client they haven't heard from in 30
    LEAVE_GRACE = 0.25 # seconds between clearing presence and unsubscribing
    BACKOFF = [1, 2, 4, 8].freeze # seconds before each reconnect, then the last for good
    UNACKED = "unsubscribed before the server acked every update"

    # `channel:` and `params:` make the subscription identifier, the way
    # yrby-client's provider does. `root:` is the root XmlText on_update
    # reports changed blocks for; nil turns that off.
    def initialize(url, params:, channel: "Y::DocumentChannel", headers: {}, doc: Y::Doc.new, root: "root", logger: nil) # rubocop:disable Metrics/ParameterLists -- the subscription's parts and the doc's
      @endpoint = Async::HTTP::Endpoint.parse(url)
      subscription = { "channel" => channel }.merge(params.transform_keys(&:to_s))
      @identifier = JSON.generate(subscription)
      # What logs and errors name the subscription by. The grant opens the
      # document, so it stays out of them.
      @label = JSON.generate(subscription.except("grant"))
      @headers = headers.map { |name, value| [name.to_s.downcase, value.to_s] }
      @doc = doc
      @awareness = Y::Awareness.new(doc.client_id)
      @presence = nil
      @session = Session.new(doc, @identifier, root: root) do |message|
        @outgoing << JSON.generate(message)
      end
      @logger = logger || Logger.new($stderr)
      @commands = Thread::Queue.new # from any thread to the reactor
      @outgoing = Thread::Queue.new # from the reactor to the socket
      @events = Thread::Queue.new   # from the reactor to whoever waits in subscribe
      @queued = 0                   # updates handed over but not yet taken up by the reactor
      @lock = Mutex.new
      @closed = false
      @turned_away = false # the server closed the client, not the caller
    end

    def on_update(&block)
      @session.on_update { |*args| callback(block, args) }
      self
    end

    def on_awareness(&block)
      @session.on_awareness { |*args| callback(block, args) }
      self
    end

    def synced? = @session.synced?

    # True while updates are in flight: handed over, sent, but not yet acked.
    def pending? = @lock.synchronize { @queued.positive? } || @session.pending?

    # True once the client has left, or the server ended its subscription
    # (rejected it on a reconnect, or asked it not to reconnect).
    def closed? = @closed

    # Connect, subscribe, and wait up to `timeout` seconds for the document
    # to arrive. Raises Y::Error when the subscription is rejected or the
    # server does not answer in time.
    def subscribe(timeout: 10)
      raise Y::Error, "the client was closed" if @closed

      @runner = Async::Task.current? ? Async { run } : Thread.new { Sync { run } }
      event = @events.pop(timeout: timeout)
      case event
      when :synced then self
      when :rejected then close_and_raise("subscription rejected for #{@label}")
      when String then close_and_raise("the server closed the connection: #{event}")
      else close_and_raise("no sync within #{timeout}s for #{@label}")
      end
    end

    # Leave: wait up to `timeout` seconds for acks of what is still in
    # flight, tell the channel, and close the socket. Nothing is delivered
    # after this. Raises Y::Error when an update was still unacked, since
    # it may never have reached the server.
    def unsubscribe(timeout: 5)
      # The server may have closed the client already, turning it away on a
      # reconnect. What it never acked is lost all the same, and the first
      # unsubscribe says so.
      if @closed
        lost = @turned_away && pending?
        @turned_away = false
        raise Y::Error, UNACKED if lost

        return self
      end

      @closed = true
      # From inside a callback the runner is the caller, so it can't be
      # waited on. It finishes leaving once the callback returns, and logs
      # an update still unacked instead.
      inside = Thread.current[:yrby_client_callback].equal?(self)
      @commands << [:close, [timeout, inside]]
      return self if inside

      @runner.is_a?(Thread) ? @runner.join(timeout + 5) : @runner&.wait
      raise Y::Error, UNACKED if pending?

      self
    rescue Async::Stop
      self
    end

    # Edit the document and send what the block changed. Returns the update,
    # or nil when there's nothing to send. A remote update applied while the
    # block runs stays out of it (see Y::Doc#edit). Raises Y::Error once the
    # client is closed, since nothing it edits then would reach anyone.
    def edit
      raise Y::Error, "the client was closed" if @closed

      # Only the block can be interrupted, so an update is never taken from
      # the document and then dropped before it's handed over.
      Thread.handle_interrupt(Object => :never) do
        update = @doc.edit { Thread.handle_interrupt(Object => :immediate) { yield @doc } }
        send_update(update)
        update
      end
    end

    # Show this client to the document's other participants, the way a
    # browser's presence does. `state` is the hash editors render, such as
    # { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }, plus a
    # caret if you have one. The client renews it every RENEW seconds and
    # clears it when it leaves.
    def presence=(state)
      @presence = JSON.generate(state)
      send_awareness(@awareness.set_local_state(@presence))
    end

    private

    attr_reader :doc

    # Hand a document update to the reactor, which keeps it until the server
    # acks it.
    def send_update(update)
      return unless update
      raise Y::Error, "the client closed before this update was sent" if @closed

      @lock.synchronize { @queued += 1 }
      @commands << [:update, update]
    end

    def send_awareness(frame)
      @commands << [:awareness, frame] if frame && !@closed
    end

    # Runs a caller's callback, marked so `unsubscribe` knows it is inside one.
    def callback(block, args)
      Thread.current[:yrby_client_callback] = self
      block.call(*args)
    ensure
      Thread.current[:yrby_client_callback] = nil
    end

    def close_and_raise(reason)
      @closed = true
      @commands << [:close, [0, false]]
      raise Y::Error, reason
    end

    # The whole life of the client, on its reactor: commands from callers
    # are applied to the session as they arrive, and the socket is kept
    # connected until the client is closed.
    def run
      @task = Async::Task.current
      pump = @task.async { each_command }
      renewal = @task.async { renew_presence }
      attempts = 0
      until @closed
        if connection == :stop
          @closed = @turned_away = true
          break
        end

        attempts += 1
        sleep BACKOFF[[attempts, BACKOFF.size].min - 1]
      end
    ensure
      pump&.stop
      renewal&.stop
    end

    # One socket: reader here, a writer task for the outgoing queue, and a
    # timer that resends unacked updates. Returns :stop when the client
    # should not reconnect, :dropped otherwise.
    def connection
      Async::WebSocket::Client.connect(@endpoint, headers: request_headers, protocols: [PROTOCOL]) do |socket|
        writer = @task.async { each_outgoing(socket) }
        timer = @task.async { retransmit }
        read_loop(socket)
      ensure
        writer&.stop
        timer&.stop
        @session.dropped
        @outgoing.clear
      end
    rescue Async::Stop
      raise
    rescue StandardError => e
      @logger.warn("Y::ActionCable::Client #{@label}: #{e.class}: #{e.message}")
      :dropped
    end

    def read_loop(socket)
      loop do
        message = @task.with_timeout(STALE) { socket.read } or return :dropped
        data = JSON.parse(message.to_str)
        case @session.receive(data)
        when :synced then @events << :synced
        when :rejected
          @events << :rejected
          return :stop
        when :disconnect
          return :dropped unless data["reconnect"] == false

          # Such as "unauthorized" from a connection that failed to connect.
          @events << data["reason"].to_s
          return :stop
        end
      end
    rescue Async::TimeoutError, JSON::ParserError => e
      @logger.warn("Y::ActionCable::Client #{@label}: #{e.class}: #{e.message}")
      :dropped
    end

    # y-protocols peers drop a client whose presence goes quiet for 30
    # seconds, so a client with presence says it again on a timer.
    def renew_presence
      loop do
        sleep RENEW
        @session.send_awareness(@awareness.set_local_state(@presence)) if @presence
      end
    end

    def retransmit
      loop do
        sleep RESEND
        @session.resend
      end
    end

    def each_outgoing(socket)
      while (text = @outgoing.pop)
        socket.write(text)
        socket.flush
      end
    end

    def each_command
      while (command, argument = @commands.pop)
        case command
        when :update
          @session.send_update(argument)
          @lock.synchronize { @queued -= 1 }
        when :awareness then @session.send_awareness(argument)
        when :close then return leave(*argument)
        end
      end
    end

    # Give in-flight updates a moment to be acked, say goodbye, let the
    # goodbye reach the socket, and stop the reactor task.
    #
    # Action Cable runs one connection's messages on a worker pool, so an
    # unsubscribe sent right behind the presence removal can be handled first,
    # and the server then drops the removal. The client lets the removal go
    # out and waits LEAVE_GRACE before unsubscribing. If it is lost anyway,
    # peers drop the presence after 30 seconds.
    def leave(timeout, inside_callback)
      deadline = now + timeout
      sleep 0.05 while @session.pending? && now < deadline
      @logger.error(UNACKED) if inside_callback && @session.pending?
      if @presence
        @session.send_awareness(@awareness.clear_local_state)
        flush
        sleep LEAVE_GRACE
      end
      @session.unsubscribe
      flush
      @task.stop
    end

    def flush
      deadline = now + 1
      sleep 0.05 until @outgoing.empty? || now > deadline
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The caller's headers, plus an Origin unless they set one. It's a new
    # array each time, because async-websocket adds the handshake's key to
    # the one it's given, and a reconnect has to send only its own key.
    def request_headers
      headers = @headers.dup
      headers.unshift(["origin", origin]) unless headers.any? { |name, _| name == "origin" }
      headers
    end

    # Action Cable checks the origin against the host unless forgery
    # protection is off; the socket's own host is always allowed.
    def origin
      "#{@endpoint.secure? ? "https" : "http"}://#{@endpoint.authority}"
    end
  end
end
