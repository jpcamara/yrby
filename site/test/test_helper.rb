ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/updates"

module ActiveSupport
  class TestCase
    # Tests don't run in parallel. The throttle counters are shared across the
    # process (Rooms' seats and size cache, ConnectionLimiter, Rack::Attack's
    # cache). Forked workers would each get their own copy, and the tests
    # assert on counts. Documents are rows, so the per-test transaction covers
    # them like any Rails model.

    # Replace the `.current` singletons before each test so seats, slots,
    # guards, and cached sizes don't leak between tests, and so a test can set
    # small caps.
    setup do
      Rooms.current = Rooms.new
      ConnectionLimiter.current = ConnectionLimiter.new
      ConnectionGuard.current = ConnectionGuard.new
      WriteBudget.current = WriteBudget.new
    end
  end
end
