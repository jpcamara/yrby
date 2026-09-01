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

  test "the limiter never reaps a slot by age — a held slot stays held" do
    # A slot is a leak only when its connection is silent past the TTL, and that
    # liveness lives in the ConnectionGuard, not here (which cannot see frames).
    # This ledger frees a slot only on release; a long-open reader is never
    # expired out from under itself. See ConnectionGuard for the leak sweep.
    limiter = ConnectionLimiter.new(max_per_ip: 1, max_total: 100)

    assert_equal :ok, status(limiter.acquire("1.2.3.4"))

    assert_equal :too_many_for_ip, status(limiter.acquire("1.2.3.4")), "the slot is still held; no age reaping"
    assert_equal 1, limiter.total
    assert_not_respond_to limiter, :sweep, "leak reaping is the ConnectionGuard's job now"
  end
end
