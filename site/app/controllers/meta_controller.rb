# The discoverability endpoints: robots.txt, sitemap.xml, and the llms.txt /
# llms-full.txt pair. Rendered from the doc and demo lists rather than committed
# as static files, so they can't drift as pages are added and the canonical host
# stays one ENV-driven value everywhere it appears.
class MetaController < ApplicationController
  before_action :cache_publicly

  # Index the docs and the demos landing pages; keep crawlers out of the demo
  # rooms. `GET /demos/:demo` mints a fresh room and redirects, so a crawler
  # that followed those links would manufacture unlimited unique URLs, the
  # room-mint trap. Disallowing each slug prefix closes both the mint and the
  # room pages while leaving the /demos index crawlable.
  def robots
    disallows = Demos.slugs.map { |slug| "Disallow: /demos/#{slug}" }
    body = <<~ROBOTS
      User-agent: *
      Content-Signal: search=yes, ai-train=yes, ai-input=yes
      #{disallows.join("\n")}
      Sitemap: #{canonical_host}/sitemap.xml
    ROBOTS
    render plain: body, content_type: "text/plain"
  end

  # The real URL set: home, the demos index, and every doc page. Static in
  # shape, so no lastmod machinery: a fresh domain needs the sitemap to be
  # found at all, not to be precise about mtimes.
  def sitemap
    urls = [canonical_host, canonical_url("/lexxy"), canonical_url("/demos")] +
           DocPage.all.map { |entry| canonical_url("/docs/#{entry.slug}") }
    xml = +%(<?xml version="1.0" encoding="UTF-8"?>\n)
    xml << %(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
    urls.each { |loc| xml << "  <url><loc>#{ERB::Util.html_escape(loc)}</loc></url>\n" }
    xml << "</urlset>\n"
    render plain: xml, content_type: "application/xml"
  end

  # The llms.txt convention: a short description, the "append .md" pointer, then
  # the doc pages listed as their `.md` URLs with one-line descriptions.
  def llms
    lines = DocPage.all.map do |entry|
      "- [#{entry.nav}](#{canonical_url("/docs/#{entry.slug}")}.md): #{entry.description}"
    end
    body = <<~LLMS
      # yrby

      yrby adds real-time collaborative editing to Rails apps. It is a Ruby
      binding for y-crdt (the Rust implementation of Yjs) plus a Rails engine.
      Documents sync over Action Cable or AnyCable and are stored in your own
      database through Active Record. Ruby can read a stored document and
      render Tiptap or Lexxy content to the same HTML the editor produces.
      It needs no Node process and no third-party service.

      For Lexxy, the lexxy-realtime gem adds collaboration with a model macro,
      a form helper, and a generator, and saves the rendered HTML back to the
      record after each change: #{canonical_host}/lexxy

      Append .md to any docs page URL to get its markdown source. Every docs
      page concatenated into one file is at #{canonical_host}/llms-full.txt.

      ## Docs

      #{lines.join("\n")}
    LLMS
    render plain: body, content_type: "text/plain"
  end

  # Every docs page concatenated, for a single-fetch corpus. Each page keeps its
  # own title and metadata front-block.
  def llms_full
    body = DocPage.all.map do |entry|
      DocPage.find(entry.slug).markdown_with_frontmatter(canonical_url("/docs/#{entry.slug}"))
    end.join("\n\n---\n\n")
    render plain: body, content_type: "text/plain"
  end

  private

  def cache_publicly
    expires_in Limits::DOCS_MAX_AGE.seconds,
               public: true,
               stale_while_revalidate: Limits::DOCS_STALE_WHILE_REVALIDATE.seconds
  end
end
