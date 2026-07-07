# frozen_string_literal: true

# Render a Yjs update (raw bytes on stdin) to HTML with the gem's native
# renderer and print it. The render-parity e2e pipes a live headless editor's
# doc through this and compares against the editor's own HTML.
#
#   bundle exec ruby frontend/render_check.rb prosemirror default
#   bundle exec ruby frontend/render_check.rb lexical root

require "y"

kind, root = ARGV
doc = Y::Doc.new
doc.apply_update($stdin.binmode.read)
html =
  case kind
  when "prosemirror" then Y::ProseMirror.new(doc).to_html(root || "default")
  when "lexical" then Y::Lexical.new(doc).to_html(root || "root")
  else abort "unknown renderer #{kind.inspect} (prosemirror|lexical)"
  end
abort "renderer returned nil for root #{root.inspect}" if html.nil?
print html
