ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/updates"

module ActiveSupport
  class TestCase
    # Not parallelized. The throttle bookkeeping in this app is process-wide
    # shared state (Rooms' seats and size cache, ConnectionLimiter, Rack::
    # Attack's cache), and forked workers would each get their own copy while
    # the tests assert on counts. Documents themselves are rows, wrapped in the
    # per-test transaction like any Rails model.

    # The singletons the app reaches for through `.current`. Swapping them per
    # test keeps one test's seats and cached sizes out of the next, and lets a
    # test set deliberately tiny caps.
    setup do
      Rooms.current = Rooms.new
      ConnectionLimiter.current = ConnectionLimiter.new
    end
  end
end
