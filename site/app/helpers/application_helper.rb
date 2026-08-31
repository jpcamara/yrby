module ApplicationHelper
  # A server-highlighted code block for hand-written snippets (the home page's
  # hero and showcase). Same pipeline and theme as the docs pages, so every
  # code block on the site is the one surface.
  def code_block(lang, source)
    Commonmarker.to_html(
      "```#{lang}\n#{source.strip}\n```",
      options: { render: { unsafe: false } },
      plugins: { syntax_highlighter: { theme: DocPage::CODE_THEME } }
    ).html_safe # unsafe: false escapes raw HTML; the source is our own literals
  end
end
