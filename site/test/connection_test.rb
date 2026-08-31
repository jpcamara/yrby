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
    assert_equal 1, ConnectionLimiter.current.count(IP), "the rejected connection must not have taken one"
  end
end
