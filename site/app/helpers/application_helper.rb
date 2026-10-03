module ApplicationHelper
  # The bundles are plain public/ files (no asset pipeline), served with
  # max-age=3600: without a fingerprint a deploy leaves browsers running last
  # hour's JS. This appends a content digest, memoized per process in
  # production: the files can only change across a restart, which resets the
  # memo. In development the digest is recomputed so the watch rebuild shows up
  # on reload.
  BUNDLE_DIGESTS = Hash.new do |cache, path|
    file = Rails.public_path.join(path.delete_prefix("/"))
    digest = File.exist?(file) ? Digest::MD5.file(file).hexdigest.first(8) : "missing"
    Rails.env.production? ? cache[path] = digest : digest
  end

  def busted(path) = "#{path}?v=#{BUNDLE_DIGESTS[path]}"

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

  # The "lines you add" treatment for the flagship samples (hero, Lexxy
  # quickstart). Context renders dimmed; the lines you actually type carry a
  # 2px accent gutter and full-brightness text, so a sample answers "what do I
  # type?" at a glance. Deliberately not syntax-highlighted: near-monochrome
  # code reads as typography, and the one accent belongs on the gutter, not
  # scattered across tokens.
  #
  # `add:` is a list of substrings; any source line containing one is an added
  # line. Substrings, not line numbers, so the marking survives edits.
  def added_lines_code(source, add:)
    lines = source.strip.split("\n").map do |line|
      added = add.any? { |needle| line.include?(needle) }
      klass = added ? "cl add" : "cl"
      %(<span class="#{klass}">#{ERB::Util.html_escape(line.empty? ? " " : line)}</span>)
    end
    # Each `.cl` is a block, so lines are joined with nothing: a literal newline
    # between them would render as a blank line under white-space: pre.
    %(<pre class="code-annotated"><code>#{lines.join}</code></pre>).html_safe
  end

  # The hero's samples. Defined here rather than inline: an ERB template
  # compiles its text into escaped string appends, and a heredoc inside an
  # output tag captures those compiled lines: apostrophes come out as \' and
  # any inner ERB delimiter leaks compiler internals. In a plain Ruby file
  # the heredoc is just a string.
  def hero_tag_line
    added_lines_code(<<~ERB, add: ["collaborative_document_tag"])
      <%= collaborative_document_tag @post, :body %>
    ERB
  end

  def hero_read_back_code
    code_block "ruby", <<~RUBY
      doc = @post.collaborative_document(:body).y_doc
      Y::Lexxy.new(doc).to_html  # or read_text / read_map / read_array
    RUBY
  end

  # The browser half of the yrby-rails path: the code lexxy-realtime writes for
  # you, shown next to it on the home page.
  def hero_bind_code
    code_block "js", <<~JS
      import "yrby-client/element"

      document.addEventListener("yrby:synced", (event) => {
        const { doc, signal } = event.detail
        const editor = attachEditor(event.target, doc)
        signal.onabort = () => editor.destroy()
      })
    JS
  end

  # The three flagship lexxy-realtime samples, rendered with the "lines you add"
  # treatment. Defined here rather than inline in the template so the ERB
  # delimiters in the form snippet (`<%= ... %>`) stay literal string content
  # and are never seen by the template's own ERB parser.
  def sample_lexxy_model
    added_lines_code(<<~RUBY, add: ["has_collaborative_rich_text"])
      class Post < ApplicationRecord
        has_collaborative_rich_text :body
      end
    RUBY
  end

  def sample_lexxy_form
    added_lines_code(<<~ERB, add: ["collaborative_rich_textarea"])
      <%= form.collaborative_rich_textarea :body %>
    ERB
  end

  def sample_lexxy_install
    added_lines_code(<<~BASH, add: ["lexxy_realtime:install"])
      bin/rails generate lexxy_realtime:install && bin/rails db:migrate
    BASH
  end

  # The proofreader's insertion caret, the site's mark. Drawn rather than set
  # as the ‸ character, which most fonts make tiny.
  def caret_mark(css_class = "text-rose-500")
    stroke = { fill: "none", stroke: "currentColor", "stroke-width": 1.8,
               "stroke-linecap": "round", "stroke-linejoin": "round" }
    tag.svg(tag.path(d: "M1.5 8.5 6 1.5l4.5 7", **stroke),
            viewBox: "0 0 12 10", class: "caret-mark #{css_class}", "aria-hidden": "true")
  end

  # A code block on a white sheet with a header naming the file and, when
  # given, where the code runs.
  CODE_SHEET_HEADER = "flex items-center gap-3 border-b border-zinc-950 bg-paper px-4 py-2 " \
                      "font-mono text-xs text-zinc-500".freeze
  CODE_SHEET = "overflow-hidden rounded-xl border border-zinc-800 bg-panel " \
               "[&_pre]:m-0 [&_pre]:rounded-none [&_pre]:border-0".freeze

  def code_sheet(path, runs_on = nil, &)
    header = tag.div(class: CODE_SHEET_HEADER) do
      safe_join([
        tag.span(path, class: "min-w-0 flex-1 truncate"),
        (tag.span(runs_on, class: "rounded-full border border-zinc-700 px-2 py-px") if runs_on)
      ].compact)
    end
    tag.div(class: CODE_SHEET) do
      header + capture(&)
    end
  end

  # The hero replay's finished state, server-rendered so the picture is
  # complete without JavaScript or with reduced motion. frontend/src/hero.js
  # replays how two people got here.
  HERO_TEXT = "Launch checklist for Friday\n• Tag the GitHub release\n• Publish yrby-client 0.6.0".freeze
  HERO_CARETS = { "ada" => HERO_TEXT.index(" release") + " release".length, "you" => HERO_TEXT.length }.freeze

  def hero_pane(viewer)
    at = 0
    parts = HERO_CARETS.sort_by(&:last).flat_map do |who, position|
      text = HERO_TEXT[at...position]
      at = position
      flag = who == viewer ? "".html_safe : tag.span(who, class: "hero-flag")
      [text, tag.span(flag, class: "hero-caret", style: "--peer: var(--color-peer-#{who})")]
    end
    safe_join(parts + [HERO_TEXT[at..]])
  end

  def hero_read_text = %("#{HERO_TEXT.gsub("\n") { "\\n" }}")

  # A JSON-LD block. Not executable script, so it is not governed by the
  # strict script-src CSP; browsers never run application/ld+json.
  def json_ld_tag(data)
    content_tag(:script, JSON.pretty_generate(data).html_safe, type: "application/ld+json")
  end
end
