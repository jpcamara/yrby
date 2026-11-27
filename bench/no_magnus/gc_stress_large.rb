# frozen_string_literal: false

# GC.stress with inputs over 1 KB (the frozen-view path), frozen and unfrozen,
# and transcoded text (UTF-16LE, ISO-8859-1), with GC.compact in another thread.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
src = Y::Doc.new(9); st = src.get_text("t"); st << ("é" * 3000)
up = src.encode_state_as_update
d = Y::Doc.new(1); t = d.get_text("t")
bg = Thread.new { loop { Array.new(100) { "x" * 100 }; GC.compact rescue nil; Thread.pass } }
GC.stress = true
30.times do |i|
  d.apply_update(up.dup)                                   # big unfrozen
  d.apply_update(up.dup.freeze)                            # big frozen
  t << ("ü" * 800).encode("UTF-16LE")                      # transcode, 1600B utf8 -> view path
  t << ("ü" * 200).encode("ISO-8859-1")                    # transcode small -> stack copy
  raise "bad #{i}" unless d.read_text("t") == t.to_s
end
GC.stress = false
bg.kill
p t.length
