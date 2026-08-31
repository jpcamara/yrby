ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/updates"

module ActiveSupport
  class TestCase
    # Not parallelized. Every throttle in this app is process-wide shared state
    # (RoomStore, ConnectionLimiter, Rack::Attack's cache), and forked workers
    # would each get their own copy while the tests assert on counts.

    # The singletons the app reaches for through `.current`. Swapping them per
    # test keeps a store full of one test's rooms out of the next one, and lets a
    # test build a deliberately tiny store.
    def use_store(**limits)
      RoomStore.current = RoomStore.new(**limits)
    end

    def use_connection_limiter(**limits)
      ConnectionLimiter.current = ConnectionLimiter.new(**limits)
    end

    setup do
      RoomStore.current = RoomStore.new
      ConnectionLimiter.current = ConnectionLimiter.new
    end
  end
end
