# frozen_string_literal: true

require "active_support"
require "active_support/cache"
require "active_support/time" # a Duration counts from Time.current, as under Rails
require_relative "client_app"

# A document on the client app and the people in it, for tests of what
# joins it from Ruby: Y::Collaborator and Y::Agent.
module DocumentRoom
  # What Y::Collaborator needs from a record's collaborative document. The grant
  # comes from the app, which owns the record.
  Document = Data.define(:key, :name) do
    # GlobalID calls from_now on expires_in, so it has to be a Duration.
    def grant(expires_in:) = expires_in.from_now && ClientApp.grant(name)
    def channel = "Y::DocumentChannel"
  end

  PERSON = { "user" => { "name" => "Ada", "color" => "#0ea5e9" } }.freeze

  def setup
    ClientApp.port
    @name = "collaborator-#{rand(1 << 32)}"
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

  # Runs a collaborator in a thread of its own, as a job would.
  def collaborator(collaborator, **)
    Thread.new do
      Thread.current.report_on_exception = false
      collaborator.run(@document, url: ClientApp.url, headers: ClientApp.headers, lock: @lock, **)
    end
  end

  # A client keeps its doc private; a test reads it to check what arrived.
  def doc_of(client) = client.send(:doc)

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
end
