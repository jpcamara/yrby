# The site's limits for the channels the gems ship. Y::DocumentChannel gets
# RoomGuarded and RecordChannelGuard, and its subclasses
# (LexxyRealtime::DocumentChannel and NoteChannel) inherit both.
#
# The authorize_document block decides which records open. Y::DocumentChannel
# only opens the example document's body. LexxyRealtime::DocumentChannel
# inherits this block, so it opens nothing: its records would have to be
# ExampleDocuments with a collaborative rich text field, and there are none.
# NoteChannel sets its own block.
Rails.application.config.to_prepare do
  Y::DocumentChannel.include RoomGuarded
  Y::DocumentChannel.prepend RecordChannelGuard
  Y::DocumentChannel.authorize_document do |record, name|
    record.is_a?(ExampleDocument) && record.id == 1 && name == "body"
  end
end
