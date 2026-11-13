# frozen_string_literal: false

# A pending interrupt wins over a Y::Error from the same call, as with magnus.
# Expect ["inner Interrupted", "after"].
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
class Interrupted < StandardError; end
d = Y::Doc.new
seen = []
begin
  Thread.handle_interrupt(Interrupted => :on_blocking) do
    Thread.current.raise(Interrupted)
    begin
      d.apply_update("bad")
    rescue Exception => e
      seen << "inner #{e.class}"
    end
    seen << "after"
  end
rescue Exception => e
  seen << "outer #{e.class}"
end
p seen
