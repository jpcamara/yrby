module ApplicationHelper
  # The bundles are plain files in public/ with no asset pipeline, served with
  # max-age=3600. Without a fingerprint, browsers keep running the old JS for
  # up to an hour after a deploy. This appends a content digest. In production
  # each process memoizes the digest, because the files only change on a
  # deploy and a deploy restarts the process. In development the digest is
  # recomputed on every call so the watch rebuild shows up on reload.
  BUNDLE_DIGESTS = Hash.new do |cache, path|
    file = Rails.public_path.join(path.delete_prefix("/"))
    digest = File.exist?(file) ? Digest::MD5.file(file).hexdigest.first(8) : "missing"
    Rails.env.production? ? cache[path] = digest : digest
  end

  def busted(path) = "#{path}?v=#{BUNDLE_DIGESTS[path]}"

  # A server-highlighted code block for the hand-written snippets on the home
  # page. It uses the same pipeline and theme as the docs pages, so every code
  # block on the site looks the same.
  def code_block(lang, source)
    Commonmarker.to_html(
      "```#{lang}\n#{source.strip}\n```",
      options: { render: { unsafe: false } },
      plugins: { syntax_highlighter: { theme: DocPage::CODE_THEME } }
    ).html_safe # unsafe: false escapes raw HTML, and the source is our own string literals
  end

  # Renders the home page and Lexxy page samples with the lines you add marked.
  # Context lines are dimmed. Added lines get a 2px accent gutter and
  # full-brightness text, so you can see at a glance what to type. These
  # samples skip syntax highlighting so the gutter is the only accent color.
  #
  # `add:` is a list of substrings, and any line containing one counts as
  # added. Matching on substrings keeps the marking correct when a sample's
  # lines move.
  def added_lines_code(source, add:)
    lines = source.strip.split("\n").map do |line|
      added = add.any? { |needle| line.include?(needle) }
      klass = added ? "cl add" : "cl"
      %(<span class="#{klass}">#{ERB::Util.html_escape(line.empty? ? " " : line)}</span>)
    end
    # Each `.cl` is a block, so the lines are joined with no separator. A
    # newline between them would render as a blank line under white-space: pre.
    %(<pre class="code-annotated"><code>#{lines.join}</code></pre>).html_safe
  end

  # The home page samples live in Ruby because a heredoc inside an ERB output
  # tag picks up the template's compiled code. Apostrophes come out as \', and
  # an inner ERB delimiter exposes the compiler's generated Ruby. In a plain
  # Ruby file the heredoc is just a string.
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

  # The browser code in the home page's "How it works" section.
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

  # The three samples on the Lexxy page. They live in Ruby so the template's
  # ERB parser never sees the `<%= ... %>` in the form snippet.
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

  # The proofreader's insertion caret, used as the site's logo mark. It's an
  # SVG because most fonts draw the ‸ character too small.
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

  # The final text of the hero replay, rendered on the server so the panes
  # look right without JavaScript or with reduced motion. frontend/src/hero.js
  # animates the typing that leads up to it.
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

  # A loaded gem's version, for the home page's status section.
  def gem_version(name) = Gem.loaded_specs[name]&.version.to_s

  # A JSON-LD block. Browsers never run application/ld+json, so the strict
  # script-src CSP doesn't apply to it.
  def json_ld_tag(data)
    content_tag(:script, JSON.pretty_generate(data).html_safe, type: "application/ld+json")
  end
end
