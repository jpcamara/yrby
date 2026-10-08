require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  IP = "203.0.113.7".freeze

  def connect_from(ip = IP)
    connect env: { "REMOTE_ADDR" => ip }
  end

  setup { ConnectionLimiter.current = ConnectionLimiter.new }

  test "an anonymous connection is accepted and takes a slot" do
    connect_from

    assert_predicate connection.connection_id, :present?
    assert_equal 1, ConnectionLimiter.current.count(IP)
  end

  test "a connection over the per-IP cap is rejected" do
    ConnectionLimiter.current = ConnectionLimiter.new(max_per_ip: 1)
    ConnectionLimiter.current.acquire(IP)

    assert_reject_connection { connect_from }
  end

  test "a connection over the process-wide cap is rejected" do
    ConnectionLimiter.current = ConnectionLimiter.new(max_total: 1)
    ConnectionLimiter.current.acquire("198.51.100.1")

    assert_reject_connection { connect_from }
  end

  test "disconnecting gives the slot back" do
    connect_from

    assert_equal 1, ConnectionLimiter.current.count(IP)

    disconnect

    assert_equal 0, ConnectionLimiter.current.count(IP)
  end

  test "a rejected connection does not leak a slot" do
    ConnectionLimiter.current = ConnectionLimiter.new(max_per_ip: 1)
    ConnectionLimiter.current.acquire(IP)

    assert_reject_connection { connect_from }
    assert_equal 1, ConnectionLimiter.current.count(IP), "the rejected connection did not take a slot"
  end

  test "disconnect releases the exact slot connect took" do
    # Releasing a connection frees its own slot, even when the same IP holds
    # others.
    limiter = ConnectionLimiter.new(max_per_ip: 5)
    ConnectionLimiter.current = limiter
    connect_from
    token = connection.slot_token

    assert_equal 1, limiter.count(IP)

    disconnect

    assert_equal 0, limiter.count(IP)
    # The released token is gone. Releasing it again does nothing and leaves
    # the other connection's slot alone.
    limiter.acquire(IP)
    limiter.release(IP, token)

    assert_equal 1, limiter.count(IP), "releasing an already freed token leaves the live slot"
  end

  test "the per-IP cap ignores a forged X-Forwarded-For" do
    # ActionDispatch::RemoteIp doesn't run on the AnyCable connect path. Rack's
    # defaults trust the LAN, so they'd accept a forged X-Forwarded-For. The
    # connection uses the app's trusted proxies, so it takes the socket address
    # and ignores the forged header.
    ConnectionLimiter.current = ConnectionLimiter.new
    connect env: { "REMOTE_ADDR" => "198.51.100.9", "HTTP_X_FORWARDED_FOR" => "1.2.3.4" }

    assert_equal 1, ConnectionLimiter.current.count("198.51.100.9"), "the socket address is the throttle key"
    assert_equal 0, ConnectionLimiter.current.count("1.2.3.4"), "the forged forwarded address is ignored"
  end
end
