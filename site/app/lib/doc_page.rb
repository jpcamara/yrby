# A documentation page: one markdown file under site/docs, rendered at request
# time.
#
# The repo README is the canonical reference for yrby's API. These pages are a
# navigable copy of it, and copies drift, so every page carries a link back to
# the README section it came from and says plainly which one wins. `source` is
# the anchor for that link.
class DocPage
  Entry = Data.define(:slug, :nav, :source)

  # Nav order.
  PAGES = [
    Entry.new(slug: "getting-started", nav: "Getting started", source: "install"),
    Entry.new(slug: "document-channel", nav: "The document channel", source: "actioncable-integration"),
    Entry.new(slug: "storage", nav: "Storage", source: "actioncable-integration"),
    Entry.new(slug: "javascript-client", nav: "The JavaScript client", source: "reliable-delivery-acks"),
    Entry.new(slug: "presence", nav: "Presence", source: "reliable-delivery-acks"),
    Entry.new(slug: "rendering", nav: "Server-side rendering", source: "rendering-to-html"),
    Entry.new(slug: "anycable", nav: "AnyCable and multi-process", source: "multi-process-deployments")
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

  # The first level-1 heading is the page title, so the title lives in the
  # markdown and can't fall out of step with it.
  def title = @title ||= @markdown[/^#\s+(.+)$/, 1] || entry.nav

  # Level-2 headings, for the in-page contents list. Anchors match the ids
  # Commonmarker's header_ids extension generates.
  def sections
    @sections ||= @markdown.scan(/^##\s+(.+)$/).flatten.map { |text| [text, anchor(text)] }
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

  private

  def anchor(text) = text.downcase.gsub(/[^a-z0-9 -]/, "").tr(" ", "-")
end
