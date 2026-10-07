# Site limits for the channel that comes with the gem. It keeps the gem's
# record lookup and storage hooks and adds the same public-demo limits the room
# channels use. This guards the gem's channel itself, because someone with a
# grant could subscribe to it by name and skip the limits on a subclass.
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
    release_seat(example_key) if example_record
  end

  private

  def authorized?(key)
    example_record.is_a?(ExampleDocument) && example_record.id == 1 && params[:name] == "body" && super
  end

  # The gem's channel looks up the record lazily, and this guard runs before it
  # does.
  def example_record = record || locate_record

  def example_key = Y::Document.key_for(example_record, :body)
end
