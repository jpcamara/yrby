# frozen_string_literal: true

require "test_helper"
require "y/action_cable/client/session"

# The client's protocol without a socket: what a Session sends for each
# thing that happens, and what it does with each message the server sends.
class ActionCableClientSessionTest < Minitest::Test
  IDENTIFIER = JSON.generate("channel" => "DocumentChannel", "id" => "room")

  def setup
    @sent = []
    @doc = Y::Doc.new
    @session = Y::ActionCable::Client::Session.new(@doc, IDENTIFIER) { |message| @sent << message }
    @server = Y::Doc.new # what the server holds
  end

  # A frame from the server, as the cable delivers it.
  def from_server(frame, identifier: IDENTIFIER)
    { "identifier" => identifier, "message" => { "update" => Base64.strict_encode64(frame) } }
  end

  def confirmed = { "identifier" => IDENTIFIER, "type" => "confirm_subscription" }

  # The frames inside what was sent: [data hash] per message command.
  def data_sent = @sent.select { |m| m["command"] == "message" }.map { |m| JSON.parse(m["data"]) }

  def frames_sent = data_sent.map { |d| Base64.strict_decode64(d["update"]) }

  def sync_step2_from_server = @server.handle_sync_message(@doc.sync_step1)[2]

  def join
    @session.receive("type" => "welcome")
    @session.receive(confirmed)
    @session.receive(from_server(sync_step2_from_server))
    @sent.clear
  end

  def test_welcome_subscribes_with_the_identifier
    assert_equal :welcome, @session.receive("type" => "welcome")
    assert_equal [{ "command" => "subscribe", "identifier" => IDENTIFIER }], @sent
  end

  def test_confirmation_answers_the_servers_step1_then_sends_ours
    @server.diff { |d| Y::Lexical.append_paragraph(d, "on the server") }
    @session.receive(from_server(@server.sync_step1)) # Action Cable sends this from `subscribed`, before confirming

    assert_empty @sent, "nothing goes out before the subscription is confirmed"
    assert_equal :confirmed, @session.receive(confirmed)

    step2, step1 = frames_sent

    assert_equal 1, step2.getbyte(1), "the server's SyncStep1 is answered with a SyncStep2"
    assert_equal @doc.sync_step1, step1
    refute_predicate @session, :synced?
  end

  def test_the_servers_step2_loads_the_doc_without_reporting_a_change
    @server.diff { |d| Y::Lexical.append_paragraph(d, "already there") }
    updates = []
    @session.on_update { |*args| updates << args }
    @session.receive("type" => "welcome")
    @session.receive(confirmed)

    assert_equal :synced, @session.receive(from_server(sync_step2_from_server))
    assert_predicate @session, :synced?
    assert_equal "already there", @doc.read_xml("root")
    assert_empty updates, "the load is not a change"
  end

  def test_an_update_after_the_load_is_applied_and_reported_with_its_blocks
    join
    updates = []
    @session.on_update { |update, doc, changed| updates << [update, doc.read_xml("root"), changed] }
    update = @server.diff { |d| Y::Lexical.append_paragraph(d, "typed in a browser") }

    assert_equal :update, @session.receive(from_server(Y.wrap_update(update)))
    assert_equal [[update, "typed in a browser", [0]]], updates
  end

  def test_our_own_update_echoed_back_is_not_reported
    join
    updates = []
    @session.on_update { |*args| updates << args }
    update = @doc.diff { |d| Y::Lexical.append_paragraph(d, "ours") }
    @session.send_update(update)
    @session.receive(from_server(Y.wrap_update(update)))

    assert_empty updates
  end

  def test_an_update_is_sent_with_an_id_and_kept_until_acked
    join
    first = @doc.diff { |d| Y::Lexical.append_paragraph(d, "one") }
    second = @doc.diff { |d| Y::Lexical.append_paragraph(d, "two") }
    @session.send_update(first)
    @session.send_update(second)

    assert_equal [1, 2], data_sent.map { |d| d["id"] } # rubocop:disable Lint/AmbiguousBlockAssociation
    assert_equal [Y.wrap_update(first), Y.wrap_update(second)], frames_sent
    assert_equal({ "command" => "message", "identifier" => IDENTIFIER }, @sent.first.except("data"))
    assert_predicate @session, :pending?

    @sent.clear
    @session.receive("identifier" => IDENTIFIER, "message" => { "ack" => 1 })
    @session.resend

    assert_equal [2], data_sent.map { |d| d["id"] }, "only the unacked update is resent"

    @session.receive("identifier" => IDENTIFIER, "message" => { "ack" => 2 })

    refute_predicate @session, :pending?
  end

  def test_updates_made_while_dropped_wait_for_the_next_confirmation
    join
    @session.dropped
    update = @doc.diff { |d| Y::Lexical.append_paragraph(d, "offline") }
    @session.send_update(update)

    assert_empty @sent
    refute_predicate @session, :synced?

    @session.receive(confirmed)

    assert_equal @doc.sync_step1, frames_sent.first, "the handshake comes first"
    assert_equal [nil, 1], data_sent.map { |d| d["id"] } # rubocop:disable Lint/AmbiguousBlockAssociation
    assert_equal Y.wrap_update(update), frames_sent.last
  end

  def test_presence_is_sent_and_said_again_on_reconnect
    join
    frame = Y::Awareness.new.set_local_state(JSON.generate(name: "Agent"))
    @session.send_awareness(frame)

    assert_equal [frame], frames_sent

    @session.dropped
    @sent.clear
    @session.receive(confirmed)

    assert_includes frames_sent, frame
  end

  def test_a_presence_frame_goes_to_on_awareness_and_leaves_the_doc_alone
    join
    seen = []
    @session.on_awareness { |frame| seen << frame }
    frame = Y::Awareness.new.set_local_state(JSON.generate(name: "Someone"))

    assert_equal :awareness, @session.receive(from_server(frame))
    assert_equal [frame], seen
    assert_nil @doc.read_xml("root")
  end

  def test_messages_for_other_subscriptions_and_garbage_are_ignored
    join
    updates = []
    @session.on_update { |*args| updates << args }
    update = @server.diff { |d| Y::Lexical.append_paragraph(d, "elsewhere") }
    other = JSON.generate("channel" => "DocumentChannel", "id" => "other")

    assert_nil @session.receive(from_server(Y.wrap_update(update), identifier: other))
    assert_equal :message, @session.receive("identifier" => IDENTIFIER, "message" => { "update" => "!!not base64" })
    assert_equal :message, @session.receive("identifier" => IDENTIFIER,
                                            "message" => { "update" => Base64.strict_encode64("\x63\x63") })
    assert_equal :ping, @session.receive("type" => "ping", "message" => 1)
    assert_equal :rejected, @session.receive("identifier" => IDENTIFIER, "type" => "reject_subscription")
    assert_equal :disconnect, @session.receive("type" => "disconnect", "reconnect" => false)
    assert_empty updates
    assert_nil @doc.read_xml("root")
  end

  def test_a_step2_after_a_reconnect_reports_what_was_missed
    join
    updates = []
    @session.on_update { |_update, _doc, changed| updates << changed }
    @session.dropped
    @server.diff { |d| Y::Lexical.append_paragraph(d, "while away") }
    @session.receive(confirmed)

    assert_equal :synced, @session.receive(from_server(sync_step2_from_server))
    assert_equal [[0]], updates
  end

  def test_unsubscribe_sends_the_command_once_subscribed
    @session.unsubscribe

    assert_empty @sent

    join
    @session.unsubscribe

    assert_equal [{ "command" => "unsubscribe", "identifier" => IDENTIFIER }], @sent
  end
end

class ActionCableClientOutboxTest < Minitest::Test
  def setup
    @outbox = Y::ActionCable::Client::Outbox.new
  end

  def test_updates_get_increasing_ids_in_order
    a = @outbox.push("a")
    b = @outbox.push("b")

    assert_equal [1, 2], [a.id, b.id]
    assert_equal [a, b], @outbox.pending
  end

  def test_an_ack_confirms_everything_up_to_its_id
    @outbox.push("a")
    @outbox.push("b")
    @outbox.push("c")

    assert @outbox.ack(2)
    assert_equal [3], @outbox.pending.map(&:id)
    assert @outbox.ack(3)
    refute_predicate @outbox, :pending?
  end

  def test_an_ack_that_names_nothing_sent_changes_nothing
    @outbox.push("a")

    refute @outbox.ack(2), "an id never sent"
    refute @outbox.ack("1"), "not an integer"
    refute @outbox.ack(nil)
    refute @outbox.ack(-1)
    refute @outbox.ack(0)
    assert_equal [1], @outbox.pending.map(&:id)
    assert @outbox.ack(1)
    refute @outbox.ack(1), "already confirmed"
  end
end
