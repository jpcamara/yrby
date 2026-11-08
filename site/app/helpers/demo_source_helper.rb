# The source panels under each demo. They read the page's own view and
# script from disk when the page renders, so what a reader sees is what runs.
# The paths are relative to the site root, which is also how the panels
# label them.
module DemoSourceHelper
  LANGUAGES = { ".erb" => "erb", ".js" => "js", ".rb" => "ruby" }.freeze

  # A file can mark the lines worth showing with a comment pair in its own
  # language (#, //, or <%#): "begin source excerpt" and "end source excerpt".
  # The panel then shows only the lines between them.
  EXCERPT = %r{^[ \t]*(?:#|//|<%#) begin source excerpt\b[^\n]*\n(.*?)^[ \t]*(?:#|//|<%#) end source excerpt\b}m

  # The Lexxy page also shows Room, which declares has_collaborative_rich_text.
  def demo_source_paths(slug)
    paths = ["app/views/demos/_#{slug}.html.erb", "frontend/src/#{slug}.js"]
    slug == "lexxy" ? ["app/models/room.rb", *paths] : paths
  end

  # The sentence under the panels' heading. The Lexxy page shows excerpts.
  def demo_source_note(slug)
    room_js = tag.code("frontend/src/room.js")
    if slug == "lexxy"
      safe_join(["Only the Lexxy parts of each file are shown. The rest is the site's shared room bar, ",
                 "presence chips, stored HTML panel, and consumer, wired up in ", room_js, " and not shown."])
    else
      safe_join(["The room bar, presence chips, status line, and consumer come from ", room_js,
                 ", which every demo shares."])
    end
  end

  # What the panel shows for a file: the whole file, or its marked lines.
  # Marked lines in a Ruby class keep the class line and its end around them.
  def demo_source(path)
    source = Rails.root.join(path).read
    excerpt = source[EXCERPT, 1] or return source
    class_line = source[/^class .*\n/] if File.extname(path) == ".rb"
    class_line ? "#{class_line}#{excerpt}end\n" : excerpt
  end

  # One highlighted file, on the same pipeline and theme as code_block. The
  # fence is longer than any run of backticks in the file, so a template
  # literal can't close it early.
  def source_file_block(path)
    source = demo_source(path)
    fence = "`" * [3, (source.scan(/`+/).map(&:length).max || 0) + 1].max
    Commonmarker.to_html(
      "#{fence}#{LANGUAGES.fetch(File.extname(path))}\n#{source}#{fence}\n",
      options: { render: { unsafe: false } },
      plugins: { syntax_highlighter: { theme: DocPage::CODE_THEME } }
    ).html_safe # unsafe: false escapes raw HTML, and the paths are fixed in this app
  end
end
