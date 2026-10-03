# Start the idle-room sweeper once the app is up.
#
# Not in the test environment: the tests drive RoomSweeper.run_once directly, and
# a background thread mutating the shared store underneath them would make them
# flaky for no benefit.
Rails.application.config.after_initialize do
  RoomSweeper.start unless Rails.env.test?
end
