require "test_helper"

class MetaTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "robots.txt allows the docs and demos index but disallows the demo rooms" do
    get "/robots.txt"

    assert_response :success
    assert_equal "text/plain", response.media_type
    Demos.slugs.each { |slug| assert_includes response.body, "Disallow: /demos/#{slug}" }
    assert_includes response.body, "Sitemap: "
    # The /demos index and /docs must not be blocked.
    assert_not_includes response.body, "Disallow: /docs"
    assert_not_includes response.body, "Disallow: /demos\n"
  end

  test "sitemap.xml lists home, demos, and every doc page" do
    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "<loc>"
    DocPage.all.each { |entry| assert_includes response.body, "/docs/#{entry.slug}</loc>" }
    assert_includes response.body, "/lexxy</loc>"
  end

  test "llms.txt lists the doc pages as .md URLs with the append-.md pointer" do
    get "/llms.txt"

    assert_response :success
    assert_includes response.body, "append .md"
    DocPage.all.each { |entry| assert_includes response.body, "/docs/#{entry.slug}.md" }
  end

  test "llms-full.txt concatenates the doc markdown" do
    get "/llms-full.txt"

    assert_response :success
    assert_includes response.body, "# Storage"
    assert_includes response.body, "# Getting started"
  end

  test "a demo room page is noindexed and canonicalizes to the demos index" do
    get "/demos/tiptap/room1"

    assert_includes response.body, %(<meta name="robots" content="noindex, nofollow">)
    assert_match %r{<link rel="canonical" href="[^"]+/demos">}, response.body
  end
end
