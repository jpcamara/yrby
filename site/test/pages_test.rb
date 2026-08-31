require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "the home page renders and is cacheable" do
    get "/"

    assert_response :success
    assert_includes response.body, "Collaborative editing that lives in your database"
    assert_includes response.headers["cache-control"], "public"
  end

  test "the home page carries the canonical, Open Graph, and JSON-LD tags" do
    get "/"

    assert_includes response.body, %(<link rel="canonical")
    assert_includes response.body, %(property="og:image")
    assert_includes response.body, %(name="twitter:card" content="summary_large_image")
    assert_includes response.body, %("@type": "SoftwareSourceCode")
  end

  test "the flagship sample marks the lines you add" do
    get "/"

    assert_includes response.body, "code-annotated"
    assert_includes response.body, %(<span class="cl add">)
  end

  test "every docs page renders" do
    DocPage.all.each do |entry|
      get "/docs/#{entry.slug}"

      assert_response :success, "#{entry.slug} did not render"
      assert_includes response.body, "repo README"
    end
  end

  test "docs pages are aggressively cacheable" do
    get "/docs/storage"

    cache_control = response.headers["cache-control"]

    assert_includes cache_control, "public"
    assert_includes cache_control, "max-age=#{Limits::DOCS_MAX_AGE}"
    assert_includes cache_control, "stale-while-revalidate=#{Limits::DOCS_STALE_WHILE_REVALIDATE}"
  end

  test "an unknown docs page is a 404" do
    get "/docs/nope"

    assert_response :not_found
  end

  test "/docs redirects to the first page" do
    get "/docs"

    assert_redirected_to "/docs/getting-started"
  end

  test "a docs page renders its markdown as HTML" do
    get "/docs/getting-started"

    assert_includes response.body, "<h2"
    assert_includes response.body, "<code>"
  end

  test "a docs page serves raw markdown for the .md route" do
    get "/docs/storage.md"

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "# Storage"
    assert_includes response.body, "Canonical:"
  end

  test "a docs page serves markdown by content negotiation" do
    get "/docs/storage", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_includes response.body, "# Storage"
  end

  test "the docs page carries its markdown alternate and TechArticle JSON-LD" do
    get "/docs/storage"

    assert_includes response.body, %(rel="alternate" type="text/markdown")
    assert_includes response.body, %("@type": "TechArticle")
    assert_includes response.body, %("@type": "BreadcrumbList")
  end

  test "the docs TOC anchors match the ids in the rendered HTML" do
    page = DocPage.find("storage")
    html = page.html

    page.sections.each do |section|
      anchor = section[1]

      assert_includes html, %(id="#{anchor}"), "TOC anchor ##{anchor} has no matching heading id"
    end
  end

  test "the docs nav lists every page" do
    get "/docs/getting-started"

    DocPage.all.each { |entry| assert_includes response.body, "/docs/#{entry.slug}" }
  end
end
