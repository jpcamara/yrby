# frozen_string_literal: true

require "active_support/duration"
require "logger"
require "y/action_cable/client"
require "y/agent/lock"

module Y
  # A Ruby process taking part in a document. It joins over the cable with a
  # grant, shows up among the people editing, hears what they write once
  # their typing settles, and leaves when they do. Subclass it, and run it
  # from a job:
  #
  #   class Reviewer < Y::Agent
  #     def presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
  #
  #     def joined
  #       edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewing.") }
  #     end
  #
  #     def changed(blocks) # ordinals of the top-level blocks people changed
  #       edit { |doc| Y::Lexxy.append_paragraph(doc, "Saw #{blocks.join(", ")}.") }
  #     end
  #   end
  #
  #   class ReviewJob < ApplicationJob
  #     def perform(post) = Reviewer.run(post.collaborative_document(:body), url: "wss://example.com/cable")
  #   end
  #
  # `run` follows the document until nobody else has been present for
  # `idle` seconds, the agent has stayed `max_stay` seconds, or `leave` is
  # called. It always clears its presence and unsubscribes on the way out.
  # An error in `joined` or `changed` ends the agent and raises out of
  # `run`; rescue it in the method to carry on.
  #
  # Only one agent works on a document at a time. Pass `as:` to allow one
  # per person instead, such as `as: person` for the agent a person brought.
  # The lock lives in `lock:`, Rails.cache by default, so it holds across
  # processes when the cache is shared. `run` returns :busy without joining
  # when another agent holds it.
  class Agent
    SETTLE = 1.5          # seconds of quiet before changed sees a burst of edits
    SETTLE_AT_MOST = 5    # seconds of steady typing before changed sees it anyway
    IDLE = 120            # seconds with nobody else present before the agent leaves
    MAX_STAY = 2 * 60 * 60
    GONE = 30             # a person whose presence hasn't renewed in this long has left
    LOCK_TTL = 60         # the lock lapses this long after the agent's last renewal

    # Runs an agent until it leaves. Returns :left, or :busy when another
    # agent holds the document.
    def self.run(document, **) = new(document, **).run

    attr_reader :document

    # `document` is a record's collaborative document, such as
    # post.collaborative_document(:body), which names its own grant and
    # channel. `channel:` overrides the channel, for an app's own
    # Y::DocumentChannel subclass, and `root:` names the root XmlText that
    # changed reports blocks of.
    def initialize(document, url:, headers: {}, channel: nil, root: "root", idle: IDLE, max_stay: MAX_STAY, # rubocop:disable Metrics/ParameterLists -- the document, the connection, and how long to stay
                   as: nil, lock: Agent.default_lock, logger: Agent.default_logger)
      @document = document
      @connect = { url: url, headers: headers, channel: channel || document.channel, root: root }
      @idle = idle
      @max_stay = max_stay
      @lock = lock && Lock.new(lock, Lock.key(document, as))
      @logger = logger
      @changes = Thread::Queue.new
      @people = Y::Awareness.new
      @renewals = {} # client id => [clock, when it last moved]
      @people_lock = Mutex.new
      @leaving = false
    end

    # Runs as a task of the caller's reactor when there is one. Otherwise it
    # starts one on the calling thread, such as a job's, and holds that
    # thread until the agent leaves.
    def run
      return :busy unless !@lock || @lock.take

      Sync do
        join
        joined
        follow
        :left
      ensure
        @client&.unsubscribe
      end
    ensure
      @lock&.release
    end

    # How the agent appears to the people in the document: the hash editors
    # render, such as { "user" => { "name" => "Reviewer" } }. nil, the
    # default, keeps it out of their roster. Override it for how the agent
    # joins, and set it to change it while the agent stays.
    attr_reader :presence

    def presence=(state)
      @presence = state
      @client&.presence = state
    end

    # Called once the agent has joined and the document has loaded.
    def joined; end

    # Called with the ordinals of the top-level blocks people changed, once
    # their typing has paused for SETTLE seconds, or after SETTLE_AT_MOST
    # seconds of steady typing. A change outside the root, such as to a map,
    # comes right away with an empty list: it's a click, not typing. The
    # agent's own edits never show up here.
    def changed(blocks); end

    def doc = @client.doc

    # Edit the document. Returns the update, or nil when nothing changed.
    # Raises Y::Error once another agent holds the document, so an agent
    # that outlived the lock stops writing.
    def edit(&)
      raise Y::Error, "another agent holds #{@document.key}" unless holding?

      @client.edit(&)
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

    # Leave once `joined` or `changed` returns.
    def leave = @leaving = true

    def self.default_lock = (Rails.cache if defined?(Rails.cache))
    def self.default_logger = (defined?(Rails.logger) && Rails.logger) || Logger.new($stderr)

    private

    def join
      grant = @document.grant(expires_in: ActiveSupport::Duration.build(@max_stay + LOCK_TTL))
      params = { grant:, name: @document.name }
      @client = Y::ActionCable::Client.new(@connect[:url], params:, logger: @logger, **@connect.except(:url))
      @client.on_update { |_update, _doc, touched| @changes << (touched || []) }
      @client.on_awareness { |frame| see(frame) }
      @client.subscribe
      state = presence
      @client.presence = state if state
    end

    def follow
      started = now
      alone_since = nil
      until @leaving || now - started > @max_stay || !holding?
        alone_since = alone?(started) ? alone_since || now : nil
        break if alone_since && now - alone_since > @idle

        touched = @changes.pop(timeout: 1)
        next unless touched

        blocks = touched.empty? ? touched : settle(touched)
        changed(blocks) if holding?
      end
    end

    def holding? = @lock.nil? || @lock.held?

    # People already in the document announce themselves only when they next
    # renew their presence, so the agent can't know it is alone until one
    # renewal window has passed since it joined.
    def alone?(started) = now - started > Y::ActionCable::Client::RENEW && people.empty?

    # Waits for a burst of edits to pause, or for SETTLE_AT_MOST seconds of
    # steady typing, and returns every block it touched.
    def settle(blocks)
      deadline = now + SETTLE_AT_MOST
      while (wait = [SETTLE, deadline - now].min).positive? && (more = @changes.pop(timeout: wait))
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

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
