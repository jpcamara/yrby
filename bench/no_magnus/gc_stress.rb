# frozen_string_literal: true

# Exercise every method of the slice with GC.stress on, so a missing
# RB_GC_GUARD or a freed-too-early buffer in the C glue shows up as a crash
# or a wrong answer. Slow by design.
#   YRBY_NATIVE=c bundle exec ruby bench/no_magnus/gc_stress.rb
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"

def check(label, got, want)
  raise "#{label}: got #{got.inspect}, want #{want.inspect}" unless got == want
end

source = Y::Doc.new(1)
text = source.get_text("t")
GC.stress = true
20.times do |i|
  update = source.edit { text << "é#{i}" }
  peer = Y::Doc.new(2)
  peer.apply_update(source.encode_state_as_update)
  check("read_text", peer.read_text("t"), text.to_s)
  check("diff", peer.encode_state_as_update(source.encode_state_vector).bytesize.positive?, true)
  check("ready", peer.update_ready?(update), true)
  check("advances", peer.update_advances?(update), false)
  check("kind", Y.message_kind(Y.wrap_update(update)), 2)
  check("from_message", Y.update_from_message(Y.wrap_update(update)).bytesize.positive?, true)
  check("roots", peer.root_names, ["t"])
  check("pending", peer.pending?, false)
  check("sync", peer.handle_sync_message(source.sync_step1).first(2), [0, 0])
  check("compacted", peer.compacted_state_update.bytesize.positive?, true)
  check("length", text.length, text.to_s.length)
  text.insert(0, +"x")
  text.delete(0, 1)
  begin
    peer.apply_update("not an update")
    raise "no error"
  rescue Y::Error
    nil
  end
end
GC.stress = false
puts "ok: #{text.to_s.length} chars"
