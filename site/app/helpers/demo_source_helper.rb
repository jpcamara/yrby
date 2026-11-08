# The source panels under each demo. They read the page's own view and
# script from disk when the page renders, so what a reader sees is what runs.
# The paths are relative to the site root, which is also how the panels
# label them.
module DemoSourceHelper
  LANGUAGES = { ".erb" => "erb", ".js" => "js" }.freeze

  def demo_source_paths(slug)
    ["app/views/demos/_#{slug}.html.erb", "frontend/src/#{slug}.js"]
  end

  # One highlighted file, on the same pipeline and theme as code_block. The
  # fence is longer than any run of backticks in the file, so a template
  # literal can't close it early.
  def source_file_block(path)
    source = Rails.root.join(path).read
    fence = "`" * [3, (source.scan(/`+/).map(&:length).max || 0) + 1].max
    Commonmarker.to_html(
      "#{fence}#{LANGUAGES.fetch(File.extname(path))}\n#{source}#{fence}\n",
      options: { render: { unsafe: false } },
      plugins: { syntax_highlighter: { theme: DocPage::CODE_THEME } }
    ).html_safe # unsafe: false escapes raw HTML, and the paths are fixed in this app
  end
end
