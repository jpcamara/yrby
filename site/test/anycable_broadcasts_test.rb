require "test_helper"
require "anycable/broadcast_adapters/http"

# AnyCable's HTTP broadcaster keeps one connection open
# (config/initializers/anycable_broadcasts.rb). A local server stands in for
# anycable-go's broadcast endpoint and counts the connections it accepts.
class AnycableBroadcastsTest < ActiveSupport::TestCase
  # Answers each request with 201. With `close_after_first`, it drops the
  # connection after its first answer without saying so, the way an idle
  # timeout on the Go side would.
  def start_server(close_after_first: false)
    @server = TCPServer.new("127.0.0.1", 0)
    @accepted = Queue.new
    @requests = Queue.new
    @thread = Thread.new do
      loop do
        socket = @server.accept
        @accepted << socket
        Thread.new(socket) { |s| serve(s, close_after_first) }
      end
    end
  end

  def serve(socket, close_after_first)
    while (line = socket.gets)
      length = 0
      while (header = socket.gets) && header != "\r\n"
        length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length")
      end
      @requests << [line, socket.read(length)]
      socket.write("HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
      break socket.close if close_after_first
    end
  end

  def adapter
    @adapter ||= AnyCable::BroadcastAdapters::Http.new(url: "http://127.0.0.1:#{@server.addr[1]}/_broadcast",
                                                       secret: "test")
  end

  def broadcast(data) = adapter.raw_broadcast({ stream: "s", data: data }.to_json)

  def received = 3.times.map { @requests.pop(timeout: 5)&.last }

  teardown do
    @adapter&.shutdown
    @thread&.kill
    @server&.close
  end

  test "broadcasts share one connection" do
    start_server
    %w[a b c].each { |data| broadcast(data) }

    assert_equal(%w[a b c], received.map { |body| JSON.parse(body)["data"] })
    assert_equal 1, @accepted.size
  end

  test "a connection the server dropped is reopened and the broadcast still goes" do
    start_server(close_after_first: true)
    adapter.define_singleton_method(:sleep) { |_seconds| nil } # skip the retry delay
    %w[a b c].each { |data| broadcast(data) }

    assert_equal(%w[a b c], received.map { |body| JSON.parse(body)["data"] })
    assert_equal 3, @accepted.size
  end
end
