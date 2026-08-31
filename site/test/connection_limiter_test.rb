require "test_helper"

class ConnectionLimiterTest < ActiveSupport::TestCase
  test "one address may hold up to the per-IP cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 2, max_total: 100)

    assert_equal :ok, limiter.acquire("1.2.3.4")
    assert_equal :ok, limiter.acquire("1.2.3.4")
    assert_equal :too_many_for_ip, limiter.acquire("1.2.3.4")
    assert_equal 2, limiter.count("1.2.3.4")
  end

  test "the per-IP cap does not affect other addresses" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100)
    limiter.acquire("1.2.3.4")

    assert_equal :too_many_for_ip, limiter.acquire("1.2.3.4")
    assert_equal :ok, limiter.acquire("5.6.7.8")
  end

  test "releasing frees the slot" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100)
    limiter.acquire("1.2.3.4")
    limiter.release("1.2.3.4")

    assert_equal 0, limiter.count("1.2.3.4")
    assert_equal 0, limiter.total
    assert_equal :ok, limiter.acquire("1.2.3.4")
  end

  test "releasing an address that holds nothing is a no-op" do
    limiter = ConnectionLimiter.new
    limiter.release("9.9.9.9")

    assert_equal 0, limiter.total
  end

  test "the process-wide cap wins over the per-IP cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 10, max_total: 2)

    assert_equal :ok, limiter.acquire("1.1.1.1")
    assert_equal :ok, limiter.acquire("2.2.2.2")
    assert_equal :too_many_connections, limiter.acquire("3.3.3.3")
    assert_equal :too_many_connections, limiter.acquire("1.1.1.1")
  end

  test "acquiring from many threads never exceeds the cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 1000, max_total: 50)
    results = Array.new(8) { Thread.new { Array.new(20) { limiter.acquire("1.2.3.4") } } }.flat_map(&:value)

    assert_equal 50, results.count(:ok)
    assert_equal 50, limiter.total
  end
end
