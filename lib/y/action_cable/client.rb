# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"
require "logger"
require "y/action_cable/client/session"

module Y::ActionCable # rubocop:disable Style/ClassAndModuleChildren
  # A Ruby process that joins a document the way a browser does: over the
  # cable's websocket, as a client of the document channel. It holds a
  # Y::Doc, follows the document, and sends its own edits and presence
  # through the channel, so the server records, acks, and distributes them
  # like anyone else's. The process touches neither the pubsub nor the
  # store. It needs the cable URL and the same way in a browser has: the
  # channel's name and params, such as a grant the app minted with
  # record.collaborative_sgid(name).
  #
  #   client = Y::ActionCable::Client.new("ws://localhost:3000/cable",
  #                                       params: { grant: post.collaborative_sgid(:body), name: "body" })
  #   client.on_update { |update, doc, changed| ... } # changed: block ordinals touched
  #   client.on_awareness { |frame| ... }
  #   client.subscribe # connects and returns once the document has arrived
  #   client.send_update(client.doc.diff { |d| Y::Lexical.append_paragraph(d, "hello") })
  #   client.send_awareness(presence.set_local_state(state.to_json))
  #   client.unsubscribe
  #
  # The client runs as a task of the reactor `subscribe` is called from
  # when there is one (Falcon, or an Async block), and in a thread of its
  # own otherwise (Puma, a script). Callbacks run on that reactor; keep
  # them short. send_update and send_awareness may be called from any
  # thread or fiber.
  #
  # Delivery is at least once, as in the JS provider: every update carries
  # an id and is kept until the server acks it, resent on a timer and after
  # a reconnect. A dropped socket reconnects with backoff. A rejected
  # subscription, or a server asking not to reconnect, ends the client.
  class Client
    PROTOCOL = "actioncable-v1-json"
    RESEND = 1     # seconds between retransmits of unacked updates
    STALE = 15     # seconds without a message before the socket is given up; the server pings every 3
    BACKOFF = [1, 2, 4, 8].freeze # seconds before each reconnect, then the last for good

    attr_reader :doc

    # `channel:` and `params:` make the subscription identifier, the way
    # yrby-client's provider does. `root:` is the root XmlText on_update
    # reports changed blocks for; nil turns that off.
    def initialize(url, params:, channel: "Y::DocumentChannel", doc: Y::Doc.new, root: "root", logger: nil) # rubocop:disable Metrics/ParameterLists -- the subscription's parts and the doc's
      @endpoint = Async::HTTP::Endpoint.parse(url)
      @identifier = JSON.generate({ "channel" => channel }.merge(params.transform_keys(&:to_s)))
      @doc = doc
      @session = Session.new(doc, @identifier, root: root) { |message| @outgoing << JSON.generate(message) }
      @logger = logger || Logger.new($stderr)
      @commands = Thread::Queue.new # from any thread to the reactor
      @outgoing = Thread::Queue.new # from the reactor to the socket
      @events = Thread::Queue.new   # from the reactor to whoever waits in subscribe
      @queued = 0                   # updates handed over but not yet taken up by the reactor
      @lock = Mutex.new
      @closed = false
    end

    def on_update(&)
      @session.on_update(&)
      self
    end

    def on_awareness(&)
      @session.on_awareness(&)
      self
    end

    def synced? = @session.synced?

    # True while updates are in flight: handed over, sent, but not yet acked.
    def pending? = @lock.synchronize { @queued.positive? } || @session.pending?

    # Connect, subscribe, and wait up to `timeout` seconds for the document
    # to arrive. Raises Y::Error when the subscription is rejected or the
    # server does not answer in time.
    def subscribe(timeout: 10)
      raise Y::Error, "the client was closed" if @closed

      @runner = Async::Task.current? ? Async { run } : Thread.new { Sync { run } }
      case @events.pop(timeout: timeout)
      when :synced then self
      when :rejected then close_and_raise("subscription rejected for #{@identifier}")
      else close_and_raise("no sync within #{timeout}s for #{@identifier}")
      end
    end

    # Leave: wait up to `timeout` seconds for acks of what is still in
    # flight, tell the channel, and close the socket. Nothing is delivered
    # after this.
    def unsubscribe(timeout: 5)
      return self if @closed

      @closed = true
      @commands << [:close, timeout]
      @runner.is_a?(Thread) ? @runner.join(timeout + 5) : @runner&.wait
      self
    rescue Async::Stop
      self
    end

    # Send a document update; the raw bytes Y::Doc#diff returns. Kept until
    # the server acks it.
    def send_update(update)
      return unless update && !@closed

      @lock.synchronize { @queued += 1 }
      @commands << [:update, update]
    end

    # Send a presence frame, such as one from Y::Awareness#set_local_state.
    def send_awareness(frame)
      @commands << [:awareness, frame] if frame && !@closed
    end

    private

    def close_and_raise(reason)
      @closed = true
      @commands << [:close, 0]
      raise Y::Error, reason
    end

    # The whole life of the client, on its reactor: commands from callers
    # are applied to the session as they arrive, and the socket is kept
    # connected until the client is closed.
    def run
      @task = Async::Task.current
      pump = @task.async { each_command }
      attempts = 0
      until @closed
        break if connection == :stop

        attempts += 1
        sleep BACKOFF[[attempts, BACKOFF.size].min - 1]
      end
    ensure
      pump&.stop
    end

    # One socket: reader here, a writer task for the outgoing queue, and a
    # timer that resends unacked updates. Returns :stop when the client
    # should not reconnect, :dropped otherwise.
    def connection
      Async::WebSocket::Client.connect(@endpoint, headers: [["origin", origin]], protocols: [PROTOCOL]) do |socket|
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
      @logger.warn("Y::ActionCable::Client #{@identifier}: #{e.class}: #{e.message}")
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
        when :disconnect then return data["reconnect"] == false ? :stop : :dropped
        end
      end
    rescue Async::TimeoutError, JSON::ParserError => e
      @logger.warn("Y::ActionCable::Client #{@identifier}: #{e.class}: #{e.message}")
      :dropped
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
        when :close then return leave(argument)
        end
      end
    end

    # Give in-flight updates a moment to be acked, say goodbye, let the
    # goodbye reach the socket, and stop the reactor task.
    def leave(timeout)
      deadline = now + timeout
      sleep 0.05 while @session.pending? && now < deadline
      @session.unsubscribe
      deadline = now + 1
      sleep 0.05 until @outgoing.empty? || now > deadline
      @task.stop
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Action Cable checks the origin against the host unless forgery
    # protection is off; the socket's own host is always allowed.
    def origin
      "#{@endpoint.secure? ? "https" : "http"}://#{@endpoint.authority}"
    end
  end
end
