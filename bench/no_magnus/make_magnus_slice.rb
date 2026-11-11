# frozen_string_literal: true

# Generate tmp/magnus_slice: yrby's magnus extension cut to the same slice
# the spike's C build ports (Doc minus the other handles and anchors, Text
# minus relative positions, the codec functions). Generated from the real
# sources, so the comparison is like-for-like: same code, same yrs, the only
# difference is the binding layer.
#   ruby bench/no_magnus/make_magnus_slice.rb && (cd tmp/magnus_slice/build && ruby ../extconf.rb && make)
require "fileutils"

root = File.expand_path("../..", __dir__)
src = File.join(root, "ext/yrby")
out = File.join(root, "tmp/magnus_slice")
FileUtils.rm_rf(File.join(out, "src"))
FileUtils.mkdir_p(File.join(out, "src"))
FileUtils.mkdir_p(File.join(out, "build"))

# Remove the item whose first line matches `pattern`: its doc comments and
# attributes above, through the closing brace at its indentation.
def remove_item(lines, pattern)
  start = lines.index { |l| l.match?(pattern) } or abort("no item matches #{pattern}")
  indent = lines[start][/\A */]
  finish = if lines[start].end_with?(";")
             start
           else
             (start...lines.size).find { |i| lines[i] == "#{indent}}" } or abort("no end for #{pattern}")
           end
  start -= 1 while start.positive? && lines[start - 1].match?(%r{\A#{indent}(///|#\[)})
  lines.slice!(start..finish)
end

lib = File.readlines(File.join(src, "src/lib.rs"), chomp: true)
[
  /^\s+fn get_array\(/, /^\s+fn get_xml_text\(/, /^\s+fn get_map\(/,
  /^\s+fn apply_update_changes\(/, /^\s+fn block_at\(/, /^\s+fn find\(/,
  /^struct RbLexical/, /^impl RbLexical/, /^struct RbProseMirror/, /^impl RbProseMirror/,
  /^fn root_name_arg/, /^fn parse_rules/, /^fn segments_result/, /^fn segments_to_ruby/,
  /^struct Children/, /^impl Children/, /^struct RbAwareness/, /^impl RbAwareness/,
  /^fn root_positions/, /^fn contains_branch/, /^fn hash_get/, /^fn sticky_from_ruby/, /^fn json_to_ruby/,
  /^mod tests/
].each { |pattern| remove_item(lib, pattern) }
dropped = /NativeLexical|NativeProseMirror|lexical_class|prosemirror_class|awareness_class|RbAwareness|
           apply_update_changes|native_block_at|native_find|"get_map"|"get_array"|"get_xml_text"|
           map::define|array::define|xml_text::define|clear_local_state|"set_local_state"|"states"|
           "clocks"|RbLexical|RbProseMirror|RbMap|RbArray|RbXmlText|^mod\s(array|map|xml_text);|
           lexical_yjs_html|prosemirror_yjs_html|render_rules|^\s*\);?$|^\s*"clear_local_state",/x
init = lib.index { |l| l.start_with?("fn init(") }
lib = lib.each_with_index.reject { |l, i| l.match?(dropped) && (i < 40 || i > init || l.include?("is_send_sync")) }.map(&:first)
# The init's multi-line define_method calls for removed methods leave stray
# halves; the slice's init is rewritten whole instead.
init = lib.index { |l| l.start_with?("fn init(") }
finish = (init...lib.size).find { |i| lib[i] == "}" }
lib[init..finish] = <<~RUST.lines(chomp: true)
  fn init(ruby: &Ruby) -> Result<(), Error> {
      let module = ruby.define_module("Y")?;
      let standard_error: magnus::RClass = ruby.eval("StandardError")?;
      let _error_class = module.define_class("Error", standard_error)?;
      let doc_class = module.define_class("Doc", ruby.class_object())?;
      doc_class.define_singleton_method("new", function!(RbDoc::new, -1))?;
      doc_class.define_method("encode_state_vector", method!(RbDoc::encode_state_vector, 0))?;
      doc_class.define_method("encode_state_as_update", method!(RbDoc::encode_state_as_update, -1))?;
      doc_class.define_method("apply_update", method!(RbDoc::apply_update, 1))?;
      doc_class.define_method("client_id", method!(RbDoc::client_id, 0))?;
      doc_class.define_private_method("native_take_unsent", method!(RbDoc::take_unsent, 0))?;
      doc_class.define_private_method("native_keep_unsent", method!(RbDoc::keep_unsent, 1))?;
      doc_class.define_method("root_names", method!(RbDoc::root_names, 0))?;
      doc_class.define_method("read_text", method!(RbDoc::read_text, 1))?;
      doc_class.define_method("read_xml", method!(RbDoc::read_xml, 1))?;
      doc_class.define_method("read_map", method!(RbDoc::read_map, 1))?;
      doc_class.define_method("read_array", method!(RbDoc::read_array, 1))?;
      doc_class.define_method("pending?", method!(RbDoc::pending, 0))?;
      doc_class.define_method("compacted_state_update", method!(RbDoc::compacted_state_update, 0))?;
      doc_class.define_method("get_text", method!(RbDoc::get_text, 1))?;
      doc_class.define_method("update_ready?", method!(RbDoc::update_ready, 1))?;
      doc_class.define_method("update_advances?", method!(RbDoc::update_advances, 1))?;
      doc_class.define_method("sync_step1", method!(RbDoc::sync_step1, 0))?;
      doc_class.define_method("handle_sync_message", method!(RbDoc::handle_sync_message, 1))?;
      module.define_class("NativeLexical", ruby.class_object())?;
      module.define_class("NativeProseMirror", ruby.class_object())?;
      text::define(ruby, module)?;
      module.define_module_function("wrap_update", function!(wrap_update, 1))?;
      module.define_module_function("message_kind", function!(message_kind, 1))?;
      module.define_module_function("update_from_message", function!(update_from_message, 1))?;
      module.const_set("MSG_SYNC", 0u8)?;
      module.const_set("MSG_AWARENESS", 1u8)?;
      module.const_set("MSG_SYNC_STEP1", 0u8)?;
      module.const_set("MSG_SYNC_STEP2", 1u8)?;
      module.const_set("MSG_SYNC_UPDATE", 2u8)?;
      Ok(())
  }
RUST
lib.unshift("#![allow(dead_code, unused_imports)]")
File.write(File.join(out, "src/lib.rs"), "#{lib.join("\n")}\n")

text = File.readlines(File.join(src, "src/text.rs"), chomp: true)
[/^\s+fn native_relative_position\(/, /^\s+fn index_at\(/, /^mod tests/].each { |p| remove_item(text, p) }
text.reject! { |l| l.include?("RbText::index_at") }
at = text.index { |l| l.include?('"native_relative_position",') }
text.slice!((at - 1)..(at + 2)) if at
File.write(File.join(out, "src/text.rs"), "#{text.join("\n")}\n")

%w[shared.rs protocol.rs read.rs].each { |f| FileUtils.cp(File.join(src, "src", f), File.join(out, "src", f)) }

cargo = File.read(File.join(src, "Cargo.toml"))
cargo = cargo.lines.reject { |l| l.match?(/yjs-html|lexical-yjs-html|prosemirror-yjs-html|^\[dev-dependencies\]|rb-sys-env|rb-sys-test-helpers|features = \["embed"\]/) }.join
File.write(File.join(out, "Cargo.toml"), "[workspace]\n\n#{cargo}")
FileUtils.cp(File.join(src, "Cargo.lock"), File.join(out, "Cargo.lock")) if File.exist?(File.join(src, "Cargo.lock"))
File.write(File.join(out, "extconf.rb"), <<~RUBY)
  require "mkmf"
  require "rb_sys/mkmf"
  create_rust_makefile("y/yrby")
RUBY
puts "wrote #{out}"
