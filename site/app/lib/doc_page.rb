# A documentation page: one markdown file under site/docs, rendered at request
# time.
#
# The repo README is the reference for yrby's API, and these pages are a copy
# that's easier to browse. Copies drift, so every page links back to the
# README section it came from and says to trust the README if they disagree.
# `source` is the anchor for that link.
class DocPage
  # `seo_title` and `description` set the <title> and meta description. They
  # let a page use words people search for when its h1 is a short nav name
  # like "Storage" or "Presence". Both fall back to the markdown when unset.
  Entry = Data.define(:slug, :nav, :source, :seo_title, :description)

  # Nav order.
  PAGES = [
    Entry.new(
      slug: "getting-started", nav: "Getting started", source: "install",
      seo_title: "Getting started: Yjs in Rails with yrby",
      description: "Add real-time collaborative editing to a Rails app with yrby. Install " \
                   "the gems, run the generator, render one tag, and bind an editor in the browser."
    ),
    Entry.new(
      slug: "document-channel", nav: "The document channel", source: "actioncable-integration",
      seo_title: "The document channel: Yjs sync over Action Cable · yrby",
      description: "How yrby syncs Yjs documents over Action Cable. Covers the built-in " \
                   "channel, writing your own, authorization, and delivery guarantees."
    ),
    Entry.new(
      slug: "storage", nav: "Storage", source: "actioncable-integration",
      seo_title: "Storage: Yjs documents in Active Record · yrby",
      description: "How yrby stores Yjs documents with Active Record. Covers Y::Document " \
                   "and Y::DocumentUpdate, compaction, encryption, and writing your own store."
    ),
    Entry.new(
      slug: "javascript-client", nav: "The JavaScript client", source: "reliable-delivery-acks",
      seo_title: "The JavaScript client: a Yjs provider for Rails · yrby",
      description: "The yrby-client browser package. Covers the yrby-document element, " \
                   "document sessions, ActionCableProvider, connection status, and acks."
    ),
    Entry.new(
      slug: "presence", nav: "Presence", source: "reliable-delivery-acks",
      seo_title: "Presence: live cursors and awareness in Rails · yrby",
      description: "Live cursors and presence with yrby. Covers publishing who is " \
                   "editing, listing who is here, editor bindings, and AnyCable whispers."
    ),
    Entry.new(
      slug: "rendering", nav: "Server-side rendering", source: "rendering-to-html",
      seo_title: "Server-side rendering: Yjs documents to HTML in Ruby · yrby",
      description: "Render Yjs documents to HTML in Ruby with Y::Tiptap and Y::Lexxy. " \
                   "The output matches the editor's own, and you can add rules for custom nodes and marks."
    ),
    Entry.new(
      slug: "anycable", nav: "AnyCable and multi-process", source: "multi-process-deployments",
      seo_title: "AnyCable and multi-process deployments · yrby",
      description: "Running yrby across several processes and on AnyCable. Covers " \
                   "broadcasts, rebuilding from the store, presence whispers, and threads."
    )
  ].freeze

  BY_SLUG = PAGES.index_by(&:slug).freeze

  README_URL = "https://github.com/jpcamara/yrby/blob/main/README.md".freeze

  # The syntect theme Commonmarker uses to highlight fenced code on the server.
  # InspiredGitHub is a light theme whose colors read well on the white code
  # sheets. The stylesheet overrides its background to match.
  CODE_THEME = "InspiredGitHub".freeze

  ROOT = Rails.root.join("docs")

  class << self
    def find(slug)
      entry = BY_SLUG[slug.to_s]
      return nil if entry.nil?

      # Cached in production, re-read in development so editing a markdown file
      # shows up on reload.
      if Rails.env.development?
        new(entry)
      else
        cache[entry.slug] ||= new(entry)
      end
    end

    def all = PAGES

    private

    def cache = @cache ||= {}
  end

  attr_reader :entry

  def initialize(entry)
    @entry = entry
    @markdown = ROOT.join("#{entry.slug}.md").read
  end

  def slug = entry.slug

  def nav = entry.nav

  def source_url = "#{README_URL}##{entry.source}"

  # The page title is the first level-1 heading in the markdown, so the two
  # always match.
  def title = @title ||= @markdown[/^#\s+(.+)$/, 1] || entry.nav

  # The <title> and meta description. Fall back to the on-page title and a
  # short default when the entry doesn't override them.
  def seo_title = entry.seo_title || "#{title} · yrby"

  def description = entry.description || "yrby documentation: #{title}."

  # Level-2 headings for the in-page contents list. They're read from the
  # rendered HTML so the anchors use the ids Commonmarker generated. Slugifying
  # the text again here could produce different ids and dead links.
  def sections
    @sections ||= Nokogiri::HTML5.fragment(html).css("h2[id]").map { |h| [h.text, h["id"]] }
  end

  # `unsafe: false` makes Commonmarker escape raw HTML in the markdown, so the
  # result is safe to mark html_safe. We write these markdown files ourselves,
  # but a renderer should still escape by default.
  def html
    @html ||= Commonmarker.to_html(
      @markdown,
      options: {
        extension: { table: true, autolink: true, strikethrough: true,
                     header_ids: "", footnotes: false },
        render: { hardbreaks: false, unsafe: false }
      },
      plugins: { syntax_highlighter: { theme: CODE_THEME } }
    ).html_safe
  end

  # The raw markdown with a short metadata block on top, for the `.md` route
  # and `Accept: text/markdown`. Coding agents read markdown best. The body
  # keeps its own `#` title. The block adds the description, the page URL, and
  # a link to the README section the page copies.
  def markdown_with_frontmatter(canonical_url)
    <<~FRONT + @markdown
      > #{description}

      Canonical: #{canonical_url}
      Source (authoritative): #{source_url}

      ---

    FRONT
  end
end
