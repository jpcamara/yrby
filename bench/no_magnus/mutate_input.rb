# frozen_string_literal: false

# Another thread swaps a large input's bytes between a valid update and junk
# while it's being applied. Each call must see one or the other whole: it
# applies or raises Y::Error, never crashes or applies torn bytes.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
src = Y::Doc.new(5); src.get_text("t") << ("x" * 20_000)
good = src.encode_state_as_update
junk = ("\xff" * good.bytesize).b
buf = +good.dup
stop = false
m = Thread.new { i = 0; until stop; buf.replace(i.even? ? junk : good); buf.setbyte(5, buf.getbyte(5)); i += 1; end }
ok = bad = 0
ENV.fetch("N","200").to_i.times do
  s = buf # same object; contents swapped under us
  begin
    Y::Doc.new.apply_update(s); ok += 1
  rescue Y::Error
    bad += 1
  end
end
stop = true; m.join
puts "ok=#{ok} errors=#{bad} (errors expected only when buf held junk at call time)"
