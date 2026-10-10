# frozen_string_literal: true

require "test_helper"
require "y/agent"
require "active_support"
require "active_support/cache"
require_relative "support/client_app"

# Y::Agent against a Rails app running the shipped Y::DocumentChannel: it
# joins with a grant, appears to the people in the document, reacts to
# their edits, and leaves when they do.
class AgentTest < Minitest::Test
  # What Y::Agent needs from a record's collaborative document. The grant
  # comes from the app, which owns the record.
  Document = Data.define(:key, :name) do
    def grant(**) = ClientApp.grant(name)
  end

  PERSON = { "user" => { "name" => "Ada", "color" => "#0ea5e9" } }.freeze
  AGENT = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }.freeze

  def setup
    ClientApp.port
    @name = "agent-#{rand(1 << 32)}"
    @document = Document.new(key: "page/1/#{@name}", name: @name)
    @lock = ActiveSupport::Cache::MemoryStore.new
    @clients = []
  end

  def teardown
    @clients.each(&:unsubscribe)
  end

  # A person in the document: an editor with presence, as a browser would be.
  def person
    client = Y::ActionCable::Client.new(ClientApp.url, params: { grant: ClientApp.grant(@name), name: @name },
                                                       headers: ClientApp.headers, logger: Logger.new(File::NULL))
    @clients << client
    client.subscribe
    client.presence = PERSON
    client
  end

  def agent(**, &)
    Thread.new do
      Y::Agent.run(@document, url: ClientApp.url, headers: ClientApp.headers, presence: AGENT, lock: @lock,
                              logger: Logger.new(File::NULL), **, &)
    end
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (value = yield)
      raise "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    value
  end

  def roster(client)
    names = Y::Awareness.new
    client.on_awareness { |frame| names.apply_update(frame) }
    -> { names.states.values.compact.map { |state| state.dig("user", "name") } }
  end

  def test_the_agent_answers_an_edit_and_leaves_when_the_person_does
    ada = person
    names = roster(ada)
    run = agent(idle: 1) do |a|
      a.edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewer here.") }
      a.on_change do |blocks|
        a.edit { |doc| Y::Lexxy.append_paragraph(doc, "Saw block #{blocks.join(", ")}.") }
      end
    end

    wait_until { ada.doc.read_xml("root").to_s.include?("Reviewer here.") }
    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    assert(wait_until { ada.doc.read_xml("root").to_s.include?("Saw block 1.") })

    ada.unsubscribe

    # It waits one presence renewal window after joining before it can tell
    # it is alone, then `idle` more.
    assert_equal :left, run.join(Y::ActionCable::Client::RENEW + 10)&.value
  end

  def test_a_second_agent_on_the_same_document_is_turned_away
    @lock.write("yrby:agent:#{@document.key}", "another agent")

    assert_equal :busy, agent.join(5)&.value
  end

  def test_an_error_in_a_handler_is_reported_and_the_agent_carries_on
    ada = person
    names = roster(ada)
    errors = Queue.new
    attempts = 0
    run = agent(idle: 1) do |a|
      a.on_error { |e| errors << e.message }
      a.on_change do
        attempts += 1
        raise "the model timed out" if attempts == 1

        a.edit { |doc| Y::Lexxy.append_paragraph(doc, "Second try worked.") }
      end
    end

    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "first") }

    assert_equal "the model timed out", errors.pop(timeout: 10)

    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "second") }

    assert(wait_until { ada.doc.read_xml("root").to_s.include?("Second try worked.") })
    run.kill
  end
end
