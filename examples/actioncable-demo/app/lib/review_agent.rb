# frozen_string_literal: true

# A Ruby agent that joins a document as a live collaborator. It follows the
# document through a peer, one live doc for the whole run, so it sees
# people's edits as they happen. It types its review into the document as
# the reviewer produces it, then stays: it considers changes once the
# typing pauses, answers lines addressed to it, and works through its own
# list. What it is doing is always in its cursor label and in the log under
# the editor, and its caret only goes where it is working. It leaves when
# nobody else has been here for a while. The presence is Y::Awareness; the
# writing is Y::Lexical over Y::XmlText, recorded and broadcast like any
# other edit.
#
# The peer is a Y::ActionCable::Peer by default: the agent runs inside the
# web server, follows the cable's pubsub, and records its own edits. Given a
# cable `url:`, or a Y::ActionCable::Client as the peer, it runs anywhere,
# joined over the websocket like a browser, and the server records, acks,
# and distributes what it writes (see bin/agent-client and AgentInvite).
class ReviewAgent
  include AgentPresence
  include AgentReactions
  include AgentWork
  include AgentReview

  QUIET = 1.5 # seconds without further edits before the agent notes a change
  TURN = 0.1 # seconds between turns while writing: a word or so per turn
  KEEP_ALIVE = 15 # presence expires in editors after 30s of silence; refresh before that

  EMPTY_FOR = 120 # seconds with nobody else here before the agent leaves
  MAX_STAY = 2 * 60 * 60
  # "@agent" with nothing after it is a request still being typed.
  UNFINISHED = /\A@agent(\s+(take|rewrite\s+this))?\s*\z/i

  def initialize(document_id, reviewer: Reviewer.default, stay: MAX_STAY, peer: nil, url: nil)
    @document_id = document_id
    @reviewer = reviewer
    @stay = stay
    @presence = Y::Awareness.new
    @changes = Queue.new
    @peer = peer || (url ? socket_client(document_id, url) : Y::ActionCable::Peer.new(document_id))
    @list = nil
    @recent_changes = []
  end

  def run
    @peer.on_update { |_update, _doc, changed| @changes << changed }
    @peer.on_awareness { |frame| see_presence(frame) }
    join
    Rails.logger.info("agent: joined #{@document_id} with #{root.xml_text_count} blocks")
    @reviewer.on_thinking = ->(delta) { think(delta) } if @reviewer.respond_to?(:on_thinking=)
    start_heartbeat
    introduce
    AgentReview::REVIEW_ON_JOIN ? start_review : announce_next
    @next_scan = 0 # the first task starts once the review is written
    watch
  ensure
    stop_heartbeat
    publish_presence(@presence.clear_local_state)
    @peer.unsubscribe
  end

  private

  def doc = @peer.doc
  def root = doc.get_xml_text("root")
  def text = doc.read_xml("root").to_s

  # Stay for a while. The peer reports which blocks each update touched, and
  # never reports this agent's own edits. A changed block is highlighted; once
  # the typing pauses, a line addressed to @agent gets an answer or is acted
  # on, and any other change is considered. Between changes the agent does
  # its own work from its list, a few chunks at a time.
  def watch
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    empty_since = nil
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < @stay
      if people_here.empty?
        empty_since ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - empty_since > EMPTY_FOR
      else
        empty_since = nil
      end
      changed = @changes.pop(timeout: busy? ? TURN : 2)
      next idle_tick unless changed

      index = settle(changed)
      next unless index && index < root.xml_text_count

      handle(request_in(@recent_changes) || index)
      @changes.clear # what arrived while the agent was writing is not news
    end
  end

  # Let a burst of typing settle; returns the last block changed.
  def settle(changed)
    index = changed.last
    @recent_changes = changed.dup
    while (more = @changes.pop(timeout: QUIET))
      index = more.last || index
      @recent_changes |= more
    end
    index
  end

  # A line addressed to the agent is an instruction to edit or a question.
  # Anything else is the document changing under a collaborator: the agent
  # considers it and contributes only when that clearly helps.
  # A burst of typing that ends with Enter changes two blocks: the request
  # and the empty one after it. The request is the one to act on.
  def request_in(indexes)
    indexes.select { |i| i < root.xml_text_count }.find { |i| block_text(i).strip.match?(/\A@agent\b/i) }
  end

  # A failure while reacting is reported in the ledger; the agent stays.
  def handle(index)
    react_to(index)
  rescue StandardError => e
    report_failure("your request", e)
  end

  def react_to(index)
    line = block_text(index)
    return if line.strip.match?(UNFINISHED)

    if line.match?(/\A@agent\b/i)
      asked = line.sub(/\A@agent\s*:?\s*/i, "")[0, 90]
      present("on it", end_of(root.xml_text(index)), end_of(root.xml_text(index)), sticky: true, detail: asked)
    end
    case line
    when /\A@agent\s+review\b/i then review_now(index)
    when /\A@agent\s+undo\b/i then undo_last(index)
    when /\A@agent\s+edit\b/i then edit_document(index, line)
    when /\A@agent\s+(take|pause|resume|continue|stop)\b/i then handoff(index, line)
    when /\A@agent\s+draft\s+(this|the|here)\b/i then draft_here(index)
    when /\A@agent\b/i
      if scoped_request?(line, index)
        edit_selection(index, line)
      elsif !answered?(index, line)
        answer(index, line)
      end
    else contribute(@recent_changes | [index])
    end
  end

  # Over the pubsub the document is loaded from the store after subscribing,
  # so an edit that lands in between is applied, not lost. Over the
  # websocket the handshake delivers it.
  def join
    @peer.subscribe
    return if socket?

    (bytes = Store.current.replay(@document_id)) && doc.apply_update(bytes)
  end

  def socket? = @peer.is_a?(Y::ActionCable::Client)

  def socket_client(document_id, url)
    Y::ActionCable::Client.new(url, channel: "DocumentChannel", params: { id: document_id }, logger: Rails.logger)
  end

  # One diff, on its way to everyone. Over the pubsub the agent records it
  # and broadcasts it, the way the channel does for a browser. Over the
  # websocket it sends it, and the server records, acks, and broadcasts it,
  # the way it does for a browser.
  def flush
    @flush ||= lambda do |update|
      next unless update

      if socket?
        @peer.send_update(update)
      else
        Store.current.record(@document_id, update)
        Y::ActionCable.broadcast(@document_id, update)
      end
    end
  end

  # A presence frame, on its way to everyone, by the same two routes.
  def publish_presence(frame)
    socket? ? @peer.send_awareness(frame) : Y::ActionCable.broadcast_awareness(@document_id, frame)
  end
end
