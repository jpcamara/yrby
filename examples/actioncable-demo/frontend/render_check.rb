# frozen_string_literal: true

# Render a Yjs update (raw bytes on stdin) to HTML with Y::Lexical and print
# it. The render-parity e2e pipes a live headless editor's doc through this
# and compares against the editor's own HTML.
#
#   bundle exec ruby frontend/render_check.rb root

require "y"

doc = Y::Doc.new
doc.apply_update($stdin.binmode.read)
html = Y::Lexical.new(doc).to_html(ARGV[0] || "root")
abort "Y::Lexical returned nil for root #{(ARGV[0] || 'root').inspect}" if html.nil?
print html
