require "test_helper"

class PagesTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "the home page renders and is cacheable" do
    get "/"

    assert_response :success
    assert_includes response.body, "yrby makes Rails a real Yjs backend"
    assert_includes response.headers["cache-control"], "public"
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

  test "the docs nav lists every page" do
    get "/docs/getting-started"

    DocPage.all.each { |entry| assert_includes response.body, "/docs/#{entry.slug}" }
  end
end
