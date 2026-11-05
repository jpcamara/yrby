# frozen_string_literal: true

require "active_support/duration"
require "logger"
require "y/action_cable/client"
require "y/agent/lock"

module Y
  # Takes part in a document the way a person does. It joins over the cable with a
  # grant, shows up among the people editing, hears what they write once
  # their typing settles, and leaves when they do. Subclass it, and run it
  # from a job:
  #
  #   class Reviewer < Y::Agent
  #     def joined
  #       self.presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
  #       edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewing.") }
  #     end
  #
  #     def changed(blocks) # live handles to the top-level blocks people changed
  #       edit { |doc| Y::Lexxy.append_paragraph(doc, "Saw #{blocks.map(&:text).join(" / ")}.") }
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
    ROOT = "root"         # the root XmlText Lexical and Lexxy edit, whose blocks changed reports

    # Runs an agent until it leaves. Returns :left, or :busy when another
    # agent holds the document.
    def self.run(document, **) = new(document, **).run

    attr_reader :document

    # `document` is a record's collaborative document, such as
    # post.collaborative_document(:body), which names its own grant and
    # channel.
    def initialize(document, url:, headers: {}, idle: IDLE, max_stay: MAX_STAY, as: nil, lock: Agent.default_lock) # rubocop:disable Metrics/ParameterLists -- the document, the connection, and how long to stay
      @document = document
      @url = url
      @headers = headers
      @idle = idle
      @max_stay = max_stay
      @lock = lock && Lock.new(lock, Lock.key(document, as))
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
        @client.unsubscribe # raises when an update was never acked
        :left
      ensure
        leave_after_error
      end
    ensure
      @lock&.release
    end

    # How the agent appears to the people in the document: the hash editors
    # render, such as { "user" => { "name" => "Reviewer" } }. nil, the
    # default, keeps it out of their roster. Set it in `joined`, or in
    # `initialize` to show up as the agent joins, and again to change it.
    attr_reader :presence

    def presence=(state)
      @presence = state
      @client&.presence = state
    end

    # Called once the agent has joined and the document has loaded.
    def joined; end

    # Called with live handles (Y::XmlText) to the top-level blocks people
    # changed, in document order, once their typing has paused for SETTLE
    # seconds, or after SETTLE_AT_MOST seconds of steady typing. A handle
    # stays on its block while people edit around it, and writing to one
    # whose block was deleted raises Y::Error. A change outside the root,
    # such as to a map, comes right away with an empty list: it's a click,
    # not typing. The agent's own edits never show up here.
    def changed(blocks); end

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

    # The agent's copy of the document, for its hooks to read.
    attr_reader :doc

    def join
      grant = @document.grant(expires_in: ActiveSupport::Duration.build(@max_stay + LOCK_TTL))
      params = { grant:, name: @document.name }
      @doc = Y::Doc.new
      @client = Y::ActionCable::Client.new(@url, params:, headers: @headers, channel: @document.channel, doc: @doc,
                                                 root: ROOT, logger: Agent.default_logger)
      @client.on_update { |_update, doc, touched| @changes << anchors(doc, touched || []) }
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

        touched = @changes.pop(timeout: 1)
        next unless touched

        touched = settle(touched) unless touched.empty?
        changed(blocks(touched)) if holding?
      end
    end

    # Unsubscribe on the way out of an error, which says more than an unacked
    # update would. After a normal leave this does nothing.
    def leave_after_error
      @client&.unsubscribe
    rescue Y::Error => e
      Agent.default_logger.error(e.message)
    end

    def holding? = @lock.nil? || @lock.held?

    # People already in the document announce themselves only when they next
    # renew their presence, so the agent can't know it is alone until one
    # renewal window has passed since it joined.
    def alone?(started) = now - started > Y::ActionCable::Client::RENEW && people.empty?

    # Anchors to the blocks an update touched, taken as it arrives: a later
    # update that adds or removes a block moves an ordinal, not an anchor.
    def anchors(doc, ordinals)
      root = doc.get_xml_text(ROOT) unless ordinals.empty?
      ordinals.filter_map { |ordinal| root.xml_text(ordinal)&.anchor }
    end

    # Waits for a burst of edits to pause, or for SETTLE_AT_MOST seconds of
    # steady typing, and returns the anchors of every block it touched.
    def settle(anchors)
      deadline = now + SETTLE_AT_MOST
      while (wait = [SETTLE, deadline - now].min).positive? && (more = @changes.pop(timeout: wait))
        anchors |= more
      end
      anchors
    end

    # Live handles to the blocks, in document order, leaving out any that
    # were deleted while the edits settled.
    def blocks(anchors)
      anchors.filter_map { |anchor| (ordinal = doc.block_at(anchor)) && [ordinal, doc.find(anchor)] }
             .sort_by(&:first).map(&:last)
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
