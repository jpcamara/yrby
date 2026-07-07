# frozen_string_literal: true

# Render a Yjs update (raw bytes on stdin) to HTML with Y::ProseMirror and
# print it. The render-parity e2e pipes a live headless editor's doc through
# this and compares against the editor's own HTML.
#
#   bundle exec ruby frontend/render_check.rb default

require "y"

doc = Y::Doc.new
doc.apply_update($stdin.binmode.read)
html = Y::ProseMirror.new(doc).to_html(ARGV[0] || "default")
abort "Y::ProseMirror returned nil for root #{(ARGV[0] || 'default').inspect}" if html.nil?
print html
