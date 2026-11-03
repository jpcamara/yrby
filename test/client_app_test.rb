# frozen_string_literal: true

require "test_helper"
require "y/action_cable"
require "y/action_cable/client"
require_relative "support/client_app"

# The Ruby client against a Rails app running the shipped Y::DocumentChannel:
# a process authenticated at connect, holding a signed grant, edits a
# record's document and shows up as a participant. The app runs as a
# subprocess (test/client_app/app.rb) so it has a database of its own.
class ClientAppTest < Minitest::Test
  TOKEN = ClientApp::TOKEN

  def setup
    @port = ClientApp.port
    @clients = []
  end

  def teardown
    @clients.each(&:unsubscribe)
  end

  def get(path) = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{@port}#{path}")))

  def client(name: "body", token: TOKEN)
    grant = get("/grant/#{name}").fetch("grant")
    client = Y::ActionCable::Client.new("ws://127.0.0.1:#{@port}/cable",
                                        params: { grant: grant, name: name },
                                        headers: { "Authorization" => "Bearer #{token}" },
                                        logger: Logger.new(File::NULL))
    @clients << client
    client
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def test_an_edit_is_saved_to_the_record_and_reaches_another_client
    agent = client.subscribe
    seen = Queue.new
    reader = client.on_update { |_update, doc, _changed| seen << doc.read_xml("root") }.subscribe

    agent.edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewed by the agent.") }
    wait_until { !agent.pending? }

    assert_equal "<p>Reviewed by the agent.</p>", get("/text/body").fetch("html")
    assert_equal "Reviewed by the agent.", seen.pop(timeout: 5)
    assert_equal "Reviewed by the agent.", reader.doc.read_xml("root")
  end

  def test_a_connection_without_the_token_is_turned_away
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Y::Error) { client(name: "notes", token: "wrong").subscribe(timeout: 5) }

    assert_equal "the server closed the connection: unauthorized", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_a_forged_grant_is_rejected
    forged = Y::ActionCable::Client.new("ws://127.0.0.1:#{@port}/cable",
                                        params: { grant: "forged", name: "body" },
                                        headers: { "Authorization" => "Bearer #{TOKEN}" },
                                        logger: Logger.new(File::NULL))
    @clients << forged

    error = assert_raises(Y::Error) { forged.subscribe(timeout: 3) }

    assert_match(/subscription rejected/, error.message)
  end

  def test_a_client_can_leave_from_inside_its_own_callback
    left = Queue.new
    listener = client(name: "leaving").subscribe
    listener.on_update { left << listener.unsubscribe }
    writer = client(name: "leaving").subscribe
    writer.edit { |doc| Y::Lexxy.append_paragraph(doc, "time to go") }

    assert_same listener, left.pop(timeout: 5)
  end

  def test_presence_reaches_others_and_is_cleared_when_the_agent_leaves
    watcher_presence = Y::Awareness.new
    watcher = client(name: "notes").on_awareness { |frame| watcher_presence.apply_update(frame) }.subscribe
    agent = client(name: "notes").subscribe
    agent.presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }

    wait_until { watcher_presence.states[agent.doc.client_id] }

    assert_equal "Reviewer", watcher_presence.states[agent.doc.client_id].dig("user", "name")

    agent.unsubscribe
    wait_until { watcher_presence.states[agent.doc.client_id].nil? }

    assert_predicate watcher, :synced?
  end
end
