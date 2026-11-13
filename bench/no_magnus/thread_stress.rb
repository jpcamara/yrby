# frozen_string_literal: false

# Four threads on one Doc/Text with large unfrozen inputs, one thread mutating
# a string it also pushes, one thread compacting, and one walking every live
# Y::Text through ObjectSpace. SECS=20 by default.
# Expect errors: 0 and converged: true.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
src = Y::Doc.new(9); st = src.get_text("t"); st << ("é" * 3000)
big_update = src.encode_state_as_update          # > 1KB, unfrozen
doc = Y::Doc.new(1)
text = doc.get_text("t")
stop = false
errors = Queue.new
threads = []
4.times do |i|
  threads << Thread.new do
    n = 0
    until stop
      begin
        u = big_update.dup                       # unfrozen heap string -> view path
        doc.apply_update(u)
        text << "x#{i}"
        text.insert(0, "é" * (n % 50))
        text.delete(0, n % 7)
        doc.read_text("t")
        doc.edit { text << "y" }
        doc.encode_state_as_update(doc.encode_state_vector)
        doc.handle_sync_message(src.sync_step1)
        Y.update_from_message(Y.wrap_update(u))
        doc.get_text("t#{n % 5}") << ("z" * 2000)  # unfrozen >1KB utf8
        n += 1
      rescue => e
        errors << e
      end
    end
  end
end
mut = Thread.new { s = +("a" * 5000); until stop; s.replace("b" * 5000); text << s; s << "c"; end }
gc = Thread.new { until stop; GC.compact; GC.start; Thread.pass; end }
# Every live Y::Text, including one get_text is still building.
probe = Thread.new do
  until stop
    ObjectSpace.each_object(Y::Text) { |t| t.length rescue Y::Error }
  end
end
sleep(Integer(ENV.fetch("SECS", "20")))
stop = true
(threads + [mut, gc, probe]).each(&:join)
puts "errors: #{errors.size}"
puts errors.pop.full_message unless errors.empty?
peer = Y::Doc.new; peer.apply_update(doc.encode_state_as_update)
puts "converged: #{peer.read_text('t') == text.to_s} len=#{text.length}"
