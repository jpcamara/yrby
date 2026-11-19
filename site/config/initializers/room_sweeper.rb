# Start the idle-room sweeper once the app is up.
#
# Skipped in the test environment. The tests call RoomSweeper.run_once
# directly, and a background thread changing the store during a test would make
# the tests flaky.
Rails.application.config.after_initialize do
  RoomSweeper.start unless Rails.env.test?
end
