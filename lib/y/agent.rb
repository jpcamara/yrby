# frozen_string_literal: true

require "logger"
require "y/action_cable/client"
require "y/agent/lock"

module Y
  # A Ruby process taking part in a document. It joins over the cable with a
  # grant, shows up among the people editing, hears what they write once
  # their typing settles, and leaves when they do. Run one from a job:
  #
  #   class ReviewJob < ApplicationJob
  #     def perform(post)
  #       Y::Agent.run(post.collaborative_document(:body),
  #                    url: "wss://example.com/cable",
  #                    headers: { "Authorization" => "Bearer #{agent_token}" },
  #                    presence: { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }) do |agent|
  #         agent.on_change { |blocks| ... } # ordinals of the top-level blocks people changed
  #         agent.edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewing.") }
  #       end
  #     end
  #   end
  #
  # The block sets the agent up and can write right away. `run` then follows
  # the document until nobody else has been present for `idle` seconds, the
  # agent has stayed `max_stay` seconds, or a handler calls `leave`. It
  # always clears its presence and unsubscribes on the way out.
  #
  # Only one agent works on a document at a time. The lock lives in `lock:`,
  # Rails.cache by default, so it holds across processes when the cache is
  # shared. `run` returns :busy without joining when another agent holds it.
  #
  # An error in the block or a handler is logged and passed to on_error, and
  # the agent keeps going.
  class Agent
    SETTLE = 1.5          # seconds of quiet before on_change sees a burst of edits
    IDLE = 120            # seconds with nobody else present before the agent leaves
    MAX_STAY = 2 * 60 * 60
    GONE = 30             # a person whose presence hasn't renewed in this long has left
    LOCK_TTL = 60         # the lock lapses this long after the agent's last renewal

    # Runs an agent until it leaves. Returns :left, or :busy when another
    # agent holds the document.
    def self.run(document, **, &) = new(document, **).run(&)

    attr_reader :client

    # `document` is a record's collaborative document, such as
    # post.collaborative_document(:body). `channel:` names an app's own
    # Y::DocumentChannel subclass, and `root:` the root XmlText that
    # on_change reports blocks of.
    def initialize(document, url:, headers: {}, presence: nil, channel: "Y::DocumentChannel", root: "root", # rubocop:disable Metrics/ParameterLists -- the document, the connection, and how long to stay
                   idle: IDLE, max_stay: MAX_STAY, lock: Agent.default_lock, logger: Agent.default_logger)
      @document = document
      @connect = { url: url, headers: headers, channel: channel, root: root }
      @presence = presence
      @idle = idle
      @max_stay = max_stay
      @lock = lock && Lock.new(lock, "yrby:agent:#{document.key}")
      @logger = logger
      @changes = Thread::Queue.new
      @change_handlers = []
      @error_handlers = []
      @people = Y::Awareness.new
      @renewals = {} # client id => [clock, when it last moved]
      @people_lock = Mutex.new
      @leaving = false
    end

    def run
      return :busy unless !@lock || @lock.take

      join
      safely("setup") { yield self } if block_given?
      follow
      :left
    ensure
      @client&.unsubscribe
      @lock&.release
    end

    # Called with the ordinals of the top-level blocks people changed, once
    # their typing has paused for SETTLE seconds. The agent's own edits never
    # show up here.
    def on_change(&block) = @change_handlers << block

    # Called with an error raised by the setup block or a handler.
    def on_error(&block) = @error_handlers << block

    def doc = @client.doc

    # Edit the document. Returns the update, or nil when nothing changed.
    # Raises Y::Error once another agent holds the document, so a handler
    # that outlived the lock stops writing.
    def edit(&)
      raise Y::Error, "another agent holds #{@document.key}" unless holding?

      @client.edit(&)
    end

    def presence=(state)
      @presence = state
      @client.presence = state
    end

    # Everyone else in the document, as { client_id => their presence state }.
    def people
      own = doc.client_id
      @people_lock.synchronize do
        @people.states.select do |id, state|
          id != own && state && (renewed = @renewals[id]) && now - renewed.last < GONE
        end
      end
    end

    # Leave once the current handler returns.
    def leave = @leaving = true

    def self.default_lock = (Rails.cache if defined?(Rails.cache))
    def self.default_logger = (defined?(Rails.logger) && Rails.logger) || Logger.new($stderr)

    private

    def join
      params = { grant: @document.grant(expires_in: @max_stay + LOCK_TTL), name: @document.name }
      @client = Y::ActionCable::Client.new(@connect[:url], params:, logger: @logger, **@connect.except(:url))
      @client.on_update { |_update, _doc, changed| @changes << (changed || []) }
      @client.on_awareness { |frame| see(frame) }
      @client.subscribe
      @client.presence = @presence if @presence
    end

    def follow
      started = now
      alone_since = nil
      until @leaving || now - started > @max_stay || !holding?
        alone_since = alone?(started) ? alone_since || now : nil
        break if alone_since && now - alone_since > @idle

        changed = @changes.pop(timeout: 1)
        next unless changed

        blocks = settle(changed)
        @change_handlers.each { |handler| safely("on_change") { handler.call(blocks) } if holding? }
      end
    end

    def holding? = @lock.nil? || @lock.held?

    # People already in the document announce themselves only when they next
    # renew their presence, so the agent can't know it is alone until one
    # renewal window has passed since it joined.
    def alone?(joined) = now - joined > Y::ActionCable::Client::RENEW && people.empty?

    # Waits for a burst of edits to pause and returns every block it touched.
    def settle(blocks)
      while (more = @changes.pop(timeout: SETTLE))
        blocks |= more
      end
      blocks.sort
    end

    # Presence frames from everyone, this agent's own included. A person's
    # editor renews their presence every 15 seconds, so a clock that stops
    # moving means they left without saying so.
    def see(frame)
      @people_lock.synchronize do
        @people.apply_update(frame)
        @people.clocks.each do |id, clock|
          @renewals[id] = [clock, now] unless @renewals[id]&.first == clock
        end
      end
    end

    def safely(what)
      yield
    rescue StandardError => e
      @logger.error("Y::Agent #{@document.key} #{what}: #{e.class}: #{e.message}")
      @error_handlers.each { |handler| handler.call(e) }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
