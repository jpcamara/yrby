module ApplicationHelper
  # The bundles are plain public/ files (no asset pipeline), served with
  # max-age=3600 — without a fingerprint a deploy leaves browsers running last
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
    # Each `.cl` is a block, so lines are joined with nothing — a literal newline
    # between them would render as a blank line under white-space: pre.
    %(<pre class="code-annotated"><code>#{lines.join}</code></pre>).html_safe
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

  # A JSON-LD block. Not executable script, so it is not governed by the
  # strict script-src CSP; browsers never run application/ld+json.
  def json_ld_tag(data)
    content_tag(:script, JSON.pretty_generate(data).html_safe, type: "application/ld+json")
  end
end
