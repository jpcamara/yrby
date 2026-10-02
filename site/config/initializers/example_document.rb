Rails.application.config.to_prepare do
  Y::DocumentChannel.include RoomGuarded
  Y::DocumentChannel.prepend ExampleDocumentGuard
end
