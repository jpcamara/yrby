# A documentation page: one markdown file under site/docs, rendered at request
# time.
#
# The repo README is the canonical reference for yrby's API. These pages are a
# navigable copy of it, and copies drift, so every page carries a link back to
# the README section it came from and says plainly which one wins. `source` is
# the anchor for that link.
class DocPage
  # `seo_title` and `description` drive the <title> and meta description, so a
  # page can end in a search phrase people actually type even when its on-page
  # h1 is a short navigational name ("Storage", "Presence"). Both fall back to
  # the markdown when unset.
  Entry = Data.define(:slug, :nav, :source, :seo_title, :description)

  # Nav order.
  PAGES = [
    Entry.new(
      slug: "getting-started", nav: "Getting started", source: "install",
      seo_title: "Getting started: Yjs in Rails with yrby",
      description: "Add real-time collaborative editing to a Rails app with yrby: install " \
                   "the gems, run the generator, render one tag, and connect a browser."
    ),
    Entry.new(
      slug: "document-channel", nav: "The document channel", source: "actioncable-integration",
      seo_title: "The document channel: Yjs sync over Action Cable · yrby",
      description: "How yrby syncs Yjs documents over Action Cable: the channel " \
                   "the gem ships, building your own, authorization, and the delivery guarantees."
    ),
    Entry.new(
      slug: "storage", nav: "Storage", source: "actioncable-integration",
      seo_title: "Storage: Yjs documents in Active Record · yrby",
      description: "How yrby persists Yjs documents in Active Record: Y::Document " \
                   "and Y::DocumentUpdate, compaction, encryption, and writing your own store."
    ),
    Entry.new(
      slug: "javascript-client", nav: "The JavaScript client", source: "reliable-delivery-acks",
      seo_title: "The JavaScript client: a Yjs provider for Rails · yrby",
      description: "The yrby-client browser package: the yrby-document element, the " \
                   "ActionCableProvider, connection status, and reliable delivery with acks."
    ),
    Entry.new(
      slug: "presence", nav: "Presence", source: "reliable-delivery-acks",
      seo_title: "Presence: live cursors and awareness in Rails · yrby",
      description: "Live cursors and awareness with yrby: publishing identity, reading " \
                   "the room, editor bindings, and whispering presence over AnyCable."
    ),
    Entry.new(
      slug: "rendering", nav: "Server-side rendering", source: "rendering-to-html",
      seo_title: "Server-side rendering: Yjs documents to HTML in Ruby · yrby",
      description: "Render Yjs documents to HTML in Ruby with yrby, matching the editor's " \
                   "own serializer byte for byte, with rules for custom nodes and marks."
    ),
    Entry.new(
      slug: "anycable", nav: "AnyCable and multi-process", source: "multi-process-deployments",
      seo_title: "AnyCable and multi-process deployments · yrby",
      description: "Running yrby across processes and on AnyCable: broadcast adapters, " \
                   "rebuilding from the store, channel state, whispers, and threads."
    )
  ].freeze

  BY_SLUG = PAGES.index_by(&:slug).freeze

  README_URL = "https://github.com/jpcamara/yrby/blob/main/README.md".freeze

  # The syntect theme Commonmarker highlights fenced code with, server-side.
  # base16-eighties.dark is a neutral dark grey whose token colors sit well on
  # the site's panel color (the stylesheet overrides the background to match).
  CODE_THEME = "base16-eighties.dark".freeze

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

  # The first level-1 heading is the on-page title, so it lives in the markdown
  # and can't fall out of step with it.
  def title = @title ||= @markdown[/^#\s+(.+)$/, 1] || entry.nav

  # The <title> and meta description. Fall back to the on-page title and a
  # short default when the entry doesn't override them.
  def seo_title = entry.seo_title || "#{title} · yrby"

  def description = entry.description || "yrby documentation: #{title}."

  # Level-2 headings, for the in-page contents list. Read from the RENDERED
  # HTML, so the anchors are the exact ids Commonmarker generated, a
  # re-slugify here could drift from the real ids and produce dead links.
  def sections
    @sections ||= Nokogiri::HTML5.fragment(html).css("h2[id]").map { |h| [h.text, h["id"]] }
  end

  # `unsafe: false` makes Commonmarker escape raw HTML in the markdown, so the
  # rendered string is safe to mark as such. The source is these files, not user
  # input, but escaping is the right default for a renderer either way.
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

  # The raw markdown, with a small metadata front-block, for the `.md` route and
  # `Accept: text/markdown`, the shape coding agents read best. The body keeps
  # its own `#` title; the front-block adds the description, the canonical URL,
  # and the pointer to the authoritative README section.
  def markdown_with_frontmatter(canonical_url)
    <<~FRONT + @markdown
      > #{description}

      Canonical: #{canonical_url}
      Source (authoritative): #{source_url}

      ---

    FRONT
  end
end
