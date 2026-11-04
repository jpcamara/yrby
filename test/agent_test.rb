# frozen_string_literal: true

require "test_helper"
require "y/agent"
require "active_support"
require "active_support/cache"
require "active_support/time" # a Duration counts from Time.current, as under Rails
require_relative "support/client_app"

# Y::Agent against a Rails app running the shipped Y::DocumentChannel: it
# joins with a grant, appears to the people in the document, reacts to
# their edits, and leaves when they do.
class AgentTest < Minitest::Test
  # What Y::Agent needs from a record's collaborative document. The grant
  # comes from the app, which owns the record.
  Document = Data.define(:key, :name) do
    # GlobalID calls from_now on expires_in, so it has to be a Duration.
    def grant(expires_in:) = expires_in.from_now && ClientApp.grant(name)
    def channel = "Y::DocumentChannel"
  end

  PERSON = { "user" => { "name" => "Ada", "color" => "#0ea5e9" } }.freeze

  # The agent the tests subclass, shown to people as Reviewer.
  class Reviewer < Y::Agent
    def presence = { "user" => { "name" => "Reviewer", "color" => "#7c3aed" } }
  end

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

  # Runs an agent in a thread of its own, as a job would.
  def agent(agent = Reviewer, **)
    Thread.new do
      Thread.current.report_on_exception = false
      agent.run(@document, url: ClientApp.url, headers: ClientApp.headers, lock: @lock,
                           logger: Logger.new(File::NULL), **)
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
    answers = Class.new(Reviewer) do
      def joined = edit { |doc| Y::Lexxy.append_paragraph(doc, "Reviewer here.") }
      def changed(blocks) = edit { |doc| Y::Lexxy.append_paragraph(doc, "Saw block #{blocks.join(", ")}.") }
    end
    run = agent(answers, idle: 1)

    wait_until { ada.doc.read_xml("root").to_s.include?("Reviewer here.") }
    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    assert(wait_until { ada.doc.read_xml("root").to_s.include?("Saw block 1.") })

    ada.unsubscribe

    # It waits one presence renewal window after joining before it can tell
    # it is alone, then `idle` more.
    assert_equal :left, run.join(Y::ActionCable::Client::RENEW + 10)&.value
  end

  # Outside a reactor, run starts one on the calling thread and holds it
  # until the agent leaves, so a job's thread is the agent's.
  def test_presence_can_change_while_the_agent_stays
    ada = person
    names = roster(ada)
    run = agent(Class.new(Reviewer) { def changed(_blocks) = self.presence = { "user" => { "name" => "Busy" } } })
    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    assert(wait_until { names.call.include?("Busy") })
    run.kill
  end

  def test_the_agent_runs_on_the_calling_thread
    seen = Queue.new
    looks = Class.new(Reviewer) do
      define_method(:joined) do
        seen << [Thread.current, Async::Task.current?]
        leave
      end
    end
    run = agent(looks)

    assert_equal :left, run.join(10)&.value
    thread, task = seen.pop

    assert_equal run, thread
    assert task, "the agent runs in a reactor"
  end

  # Someone who never pauses still gets an answer: changed runs after
  # SETTLE_AT_MOST seconds of steady typing.
  def test_steady_typing_reaches_changed_before_it_stops
    ada = person
    names = roster(ada)
    seen = Queue.new
    run = agent(Class.new(Reviewer) { define_method(:changed) { |blocks| seen << blocks } })
    wait_until { names.call.include?("Reviewer") }

    typing = Y::Agent::SETTLE_AT_MOST + 4
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + typing
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop && seen.empty?
      ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "typing") }
      sleep 0.3
    end

    refute_empty seen, "changed ran while Ada was still typing"
    run.kill
  end

  def test_leave_ends_the_agent_without_waiting_to_be_alone
    run = agent(Class.new(Reviewer) { def joined = leave })

    assert_equal :left, run.join(5)&.value
  end

  def test_a_second_agent_on_the_same_document_is_turned_away
    @lock.write("yrby:agent:#{@document.key}", "another agent")

    assert_equal :busy, agent.join(5)&.value
  end

  # With as:, each person can bring one agent, and a second for the same
  # person is turned away.
  def test_one_agent_per_person_with_as
    @lock.write(Y::Agent::Lock.key(@document, "ada"), "Ada's agent")

    assert_equal :busy, agent(as: "ada").join(5)&.value
    assert_equal :left, agent(as: "linus", max_stay: 1).join(10)&.value
  end

  # An error in changed ends the agent the way it would end a job: the agent
  # clears its presence, gives up the lock, and the error raises out of run.
  def test_an_error_in_changed_ends_the_agent_and_raises_out_of_run
    ada = person
    names = roster(ada)
    run = agent(Class.new(Reviewer) { def changed(_blocks) = raise("the model timed out") })

    wait_until { names.call.include?("Reviewer") }
    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "Please review.") }

    error = assert_raises(RuntimeError) { run.join(10) }

    assert_equal "the model timed out", error.message
    assert(wait_until { !names.call.include?("Reviewer") })
    assert_nil @lock.read("yrby:agent:#{@document.key}")
  end
end
