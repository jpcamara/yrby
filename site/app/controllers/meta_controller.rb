# The discoverability endpoints: robots.txt, sitemap.xml, and the llms.txt /
# llms-full.txt pair. Rendered from the doc and demo lists rather than committed
# as static files, so they can't drift as pages are added and the canonical host
# stays one ENV-driven value everywhere it appears.
class MetaController < ApplicationController
  before_action :cache_publicly

  # Index the docs and the demos landing pages; keep crawlers out of the demo
  # rooms. `GET /demos/:demo` mints a fresh room and redirects, so a crawler
  # that followed those links would manufacture unlimited unique URLs — the
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
  # shape, so no lastmod machinery — a fresh domain needs the sitemap to be
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

      Real-time collaborative editing that runs in Ruby and Rails, with
      document state in your own database. Documents sync over Action Cable
      and persist through Active Record; after every change the server renders
      the document back into the model as HTML, byte-identical to the editor's
      own serializer. No Node process, no third-party service. If you use
      Lexxy, lexxy-realtime wires it up with a model macro, a form helper, and
      a generator: #{canonical_host}/lexxy

      For any page on this site, append .md to the URL to get a plain markdown
      version optimized for LLMs. A concatenation of every docs page is at
      #{canonical_host}/llms-full.txt.

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
