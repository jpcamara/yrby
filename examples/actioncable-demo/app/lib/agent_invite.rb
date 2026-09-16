# frozen_string_literal: true

require "y/action_cable/client"

# The invite, POST /docs/:id/agent, as a Rack endpoint, so the answer can be
# a streaming body.
#
# Under Puma it is DocumentsController#agent: a 204, and the agent in a
# thread over the pubsub, one per document. Under Falcon the request runs
# in a fiber, and so does the agent: a child task of the request, joined
# over the cable's websocket like a browser, and the response is held open
# as a stream of its status for as long as the agent is there. Closing the
# connection ends the stream, and the agent with it: the connection is the
# registry.
#
# The stream is a Rack 3 streaming body, call(stream), which Falcon runs
# inside the request's task. A controller's response cannot carry one:
# Rails always enumerates it, and Falcon enumerates on a fiber of its own,
# where there is no task to run the agent in. Written as server-sent
# events: the page holds it with a fetch, and curl -N shows it.
class AgentInvite
  HEARTBEAT = 5 # seconds between comment lines, so proxies keep the connection

  def self.call(env)
    return DocumentsController.action(:agent).call(env) unless Async::Task.current?

    request = ActionDispatch::Request.new(env)
    body = new(request.path_parameters[:id], cable_url(request))
    [200, { "content-type" => "text/event-stream", "cache-control" => "no-cache" }, body]
  end

  # The cable the browsers are on: anycable-go when CABLE_URL points there,
  # otherwise this server's own.
  def self.cable_url(request)
    ActionCable.server.config.url.presence || "ws://#{request.host_with_port}/cable"
  end

  def initialize(document_id, url)
    @document_id = document_id
    @url = url
  end

  def call(stream)
    client = Y::ActionCable::Client.new(@url, channel: "DocumentChannel", params: { id: @document_id },
                                              logger: Rails.logger)
    agent = Async::Task.current.async { ReviewAgent.new(@document_id, peer: client).run }
    stream.write("event: agent\ndata: joined #{@document_id} over #{@url}\n\n")
    until agent.finished?
      sleep HEARTBEAT
      stream.write(": #{Time.now.utc.iso8601}\n\n")
    end
    stream.write("event: agent\ndata: left\n\n")
  rescue Protocol::HTTP::RemoteError, IOError, SystemCallError
    nil # the inviter left; the agent goes with it, below
  ensure
    agent.stop if agent && !agent.finished?
    stream.close
  end
end
