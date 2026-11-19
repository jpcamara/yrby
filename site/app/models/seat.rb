# One connection's place in one of a room's documents. RoomGuarded takes a
# seat when a client subscribes and gives it back when it unsubscribes. The
# rows are shared by every server process, so a subscribe one process handles
# and an unsubscribe another handles still meet, and the peer cap counts
# everyone. `room` is a Room, or the docs' ExampleDocument.
#
# `seen_at` says the connection is still there. RoomGuarded refreshes it at
# most once every SEAT_TOUCH_INTERVAL while frames arrive, and the sweeper
# deletes seats older than SEAT_TTL. Those belong to connections whose
# unsubscribe never arrived, such as one a crashed process was serving.
class Seat < ApplicationRecord
  belongs_to :room, polymorphic: true

  scope :stale, -> { where(seen_at: ...Limits::SEAT_TTL.seconds.ago) }
end
