# frozen_string_literal: false

# Edge-case behaviour, printed one line per case, so the two builds can be diffed:
#   bundle exec ruby bench/no_magnus/behavior_diff.rb > m.txt
#   YRBY_NATIVE=c bundle exec ruby bench/no_magnus/behavior_diff.rb > c.txt
#   diff m.txt c.txt
# Expected differences: Y::Text.new (magnus returns an empty handle) and
# encode_state_as_update with two arguments (C raises ArgumentError).
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "y"
def t(label)
  r = yield
  puts "#{label}: #{r.inspect} (#{r.respond_to?(:encoding) ? r.encoding : ''})"
rescue Exception => e
  puts "#{label}: RAISE #{e.class}: #{e.message[0,80]}"
end
d = Y::Doc.new(1)
t("new(nil)") { Y::Doc.new(nil).class }
t("new('5')") { Y::Doc.new("5") }
t("new(1.5)") { Y::Doc.new(1.5).client_id }
t("new(2**53+1)") { Y::Doc.new(2**53+1).client_id }
t("allocate") { Y::Doc.allocate.class }
t("allocate.client_id") { Y::Doc.allocate.client_id }
t("dup.client_id") { d.dup.client_id }
t("subclass") { Class.new(Y::Doc) { def initialize(*) = (super; @x = 1) }.new(3).instance_variable_get(:@x) }
t("Text.new") { Y::Text.new }
tx = d.get_text("t")
t("push binary utf8 bytes") { tx << "\xC3\xA9".b; tx.to_s }
t("push binary invalid") { tx << "\xff".b }
t("push broken utf8") { tx << "\xff".dup.force_encoding("UTF-8") }
t("push usascii high") { tx << "\xC3\xA9".dup.force_encoding("US-ASCII"); tx.to_s }
t("push utf16") { tx << "ab".encode("UTF-16LE"); tx.to_s }
t("push latin1") { tx << "\xE9".dup.force_encoding("ISO-8859-1"); tx.to_s }
t("get_text binary name") { d.get_text("\xC3\xA9".b).to_s }
t("read_text broken") { d.read_text("\xff".dup.force_encoding("UTF-8")) }
t("to_s enc") { tx.to_s }
t("sv enc") { d.encode_state_vector }
t("hsm awareness") { d.handle_sync_message("\x01\x00".b) }
t("hsm step1") { d.handle_sync_message(d.sync_step1)[0,2] }
t("hsm step2") { d.handle_sync_message(Y::Doc.new.sync_step1.tap{}.then { |_| "\x00\x01\x02\x00\x00".b }) }
t("message_kind junk") { Y.message_kind("junk") }
t("update_from_message junk") { Y.update_from_message("junk") }
t("apply bad") { d.apply_update("bad") }
t("insert float idx") { tx.insert(0.9, "z"); tx.to_s }
t("delete huge") { tx.delete(-2**63, 2**63-1); tx.to_s }
t("root_names") { d.root_names }
t("wrap nil") { Y.wrap_update(nil) }
t("esau nil") { d.encode_state_as_update(nil) }
t("esau 2 args") { d.encode_state_as_update("a", "b") }
