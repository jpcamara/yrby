require "test_helper"

class ConnectionLimiterTest < ActiveSupport::TestCase
  # acquire returns [status, token]; these helpers keep the assertions readable.
  def status(result) = result.first
  def token(result) = result.last

  test "one address may hold up to the per-IP cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 2, max_total: 100)

    assert_equal :ok, status(limiter.acquire("1.2.3.4"))
    assert_equal :ok, status(limiter.acquire("1.2.3.4"))
    assert_equal :too_many_for_ip, status(limiter.acquire("1.2.3.4"))
    assert_equal 2, limiter.count("1.2.3.4")
  end

  test "the per-IP cap does not affect other addresses" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100)
    limiter.acquire("1.2.3.4")

    assert_equal :too_many_for_ip, status(limiter.acquire("1.2.3.4"))
    assert_equal :ok, status(limiter.acquire("5.6.7.8"))
  end

  test "releasing the exact token frees the slot" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100)
    token = token(limiter.acquire("1.2.3.4"))
    limiter.release("1.2.3.4", token)

    assert_equal 0, limiter.count("1.2.3.4")
    assert_equal 0, limiter.total
    assert_equal :ok, status(limiter.acquire("1.2.3.4"))
  end

  test "releasing a token the IP does not hold is a no-op" do
    limiter = ConnectionLimiter.new(max_per_ip: 5, max_total: 100)
    limiter.acquire("1.2.3.4")
    limiter.release("1.2.3.4", "not-a-real-token")

    # The live slot is untouched — no wrongful decrement, no freeing another
    # connection's slot.
    assert_equal 1, limiter.count("1.2.3.4")
    assert_equal 1, limiter.total
  end

  test "releasing an address that holds nothing is a no-op" do
    limiter = ConnectionLimiter.new
    limiter.release("9.9.9.9", "whatever")

    assert_equal 0, limiter.total
  end

  test "a double release frees only one slot" do
    limiter = ConnectionLimiter.new(max_per_ip: 5, max_total: 100)
    a = token(limiter.acquire("1.2.3.4"))
    limiter.acquire("1.2.3.4")
    limiter.release("1.2.3.4", a)
    limiter.release("1.2.3.4", a) # the disconnect fired twice

    assert_equal 1, limiter.count("1.2.3.4"), "the second release must not free the other connection's slot"
    assert_equal 1, limiter.total
  end

  test "the process-wide cap wins over the per-IP cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 10, max_total: 2)

    assert_equal :ok, status(limiter.acquire("1.1.1.1"))
    assert_equal :ok, status(limiter.acquire("2.2.2.2"))
    assert_equal :too_many_connections, status(limiter.acquire("3.3.3.3"))
    assert_equal :too_many_connections, status(limiter.acquire("1.1.1.1"))
  end

  test "acquiring from many threads never exceeds the cap" do
    limiter = ConnectionLimiter.new(max_per_ip: 1000, max_total: 50)
    results = Array.new(8) { Thread.new { Array.new(20) { limiter.acquire("1.2.3.4").first } } }.flat_map(&:value)

    assert_equal 50, results.count(:ok)
    assert_equal 50, limiter.total
  end

  test "a leaked slot is reclaimed once it ages past the TTL" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100, max_age: 60)
    # Acquire at t=0 and never release (the Disconnect RPC that never fired).
    assert_equal :ok, status(limiter.acquire("1.2.3.4", 0))
    assert_equal :too_many_for_ip, status(limiter.acquire("1.2.3.4", 30)), "still held before the TTL"

    # A sweep past the TTL reclaims the leaked slot.
    assert_equal 1, limiter.sweep(61)
    assert_equal 0, limiter.total
    assert_equal :ok, status(limiter.acquire("1.2.3.4", 61)), "the reclaimed slot is free again"
  end

  test "acquire reaps the IP's own expired slots first, without waiting for a sweep" do
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100, max_age: 60)
    limiter.acquire("1.2.3.4", 0) # leaks

    # Past the TTL, the next acquire from the same IP drops the stale slot and
    # succeeds — no explicit sweep needed.
    assert_equal :ok, status(limiter.acquire("1.2.3.4", 61))
    assert_equal 1, limiter.count("1.2.3.4", 61)
  end

  test "a fresh slot is never reaped" do
    limiter = ConnectionLimiter.new(max_per_ip: 2, max_total: 100, max_age: 3600)
    limiter.acquire("1.2.3.4", 0)

    assert_equal 0, limiter.sweep(60), "60s is well under the hour TTL"
    assert_equal 1, limiter.total
  end

  test "sweeping empties the running total exactly" do
    limiter = ConnectionLimiter.new(max_per_ip: 100, max_total: 100, max_age: 60)
    5.times { limiter.acquire("1.1.1.1", 0) }
    3.times { limiter.acquire("2.2.2.2", 0) }

    assert_equal 8, limiter.sweep(120)
    assert_equal 0, limiter.total
    assert_equal 0, limiter.count("1.1.1.1")
  end
end
