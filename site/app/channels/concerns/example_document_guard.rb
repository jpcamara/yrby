# Site policy around the gem-shipped channel. Keep its record resolution and
# storage hooks, but apply the same public-demo limits as the room channels.
# Guard the shipped channel itself: a grant holder could otherwise name it
# directly and bypass the limits of an application subclass.
module ExampleDocumentGuard
  def subscribed
    return reject unless authorized?(nil)
    return reject unless take_seat(example_key)

    super
  end

  def receive(data)
    return reject unless authorized?(nil) && seat

    guarded_receive(data, example_key)
  end

  def unsubscribed
    release_seat(example_key) if record
  end

  private

  def authorized?(key)
    super && record.is_a?(ExampleDocument) && record.id == 1 && params[:name] == "body"
  end

  def example_key = Y::Document.key_for(record, :body)
end
