require "test_helper"

class DemosTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  test "the demo index lists every demo" do
    get "/demos"

    assert_response :success
    Demos::ALL.each { |demo| assert_includes response.body, demo.title }
  end

  test "a bare demo URL mints a room and redirects into it" do
    get "/demos/tiptap"

    assert_response :redirect
    room = response.location[%r{/demos/tiptap/(.+)\z}, 1]

    assert Demos.valid_room?(room), "#{room.inspect} is not a valid room id"
  end

  test "two visitors get different rooms" do
    get "/demos/tiptap"
    first = response.location
    get "/demos/tiptap"

    assert_not_equal first, response.location
  end

  test "every demo page renders with its document key and bundle" do
    Demos::ALL.each do |demo|
      get "/demos/#{demo.slug}/room1"

      assert_response :success, "#{demo.slug} did not render"
      assert_includes response.body, %(data-document-key="#{demo.slug}/room1")
      assert_includes response.body, "/#{demo.slug}.js"
    end
  end

  test "a demo page is never cached" do
    get "/demos/tiptap/room1"

    assert_equal "no-store", response.headers["cache-control"]
  end

  test "the demo page carries the room link and the second-window affordance" do
    get "/demos/kanban/room1"

    assert_includes response.body, "http://www.example.com/demos/kanban/room1"
    assert_includes response.body, "second-window"
  end

  test "the nav keeps the room across demos" do
    get "/demos/kanban/room1"

    Demos::ALL.reject { |d| d.slug == "kanban" }.each do |demo|
      assert_includes response.body, "/demos/#{demo.slug}/room1"
    end
  end

  test "an unknown demo is a 404" do
    get "/demos/wiki/room1"

    assert_response :not_found
  end

  test "a malformed room id is a 404" do
    get "/demos/tiptap/#{"a" * 33}"

    assert_response :not_found
  end

  test "visiting a demo page does not create a room" do
    get "/demos/tiptap/room1"

    assert_equal 0, Y::Document.count, "documents are created by the channel, not the page"
  end

  test "the lexxy page mints its note and hands the client the sgid credentials" do
    get "/demos/lexxy/room1"

    assert_response :success
    note = Note.find_by!(room: "room1")

    # Signed GlobalIDs embed a minting timestamp, so compare by what the token
    # DOES rather than its bytes: the page's sgid must locate this note under
    # the gem's field-scoped purpose.
    sgid = response.body[/data-sgid="([^"]+)"/, 1]

    assert_predicate sgid, :present?
    assert_equal note, GlobalID::Locator.locate_signed(sgid, for: Note.sgid_purpose(:body))
    assert_includes response.body, %(data-field="body")
    # The document itself is minted by the channel on first join, not the page.
    assert_equal 0, Y::Document.count
  end

  test "the lexxy editor mounts with attachments disabled" do
    get "/demos/lexxy/room1"

    assert_includes response.body, %(attachments="false")
  end

  test "the body endpoint returns the materialized column" do
    note = Note.create!(room: "room1", body: "<h1>from Ruby</h1>")

    get "/demos/lexxy/room1/body"

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    assert_equal({ "body" => note.body }, response.parsed_body)
  end

  test "the body endpoint is empty-safe" do
    get "/demos/lexxy/nothere/body"

    assert_response :success
    assert_nil response.parsed_body["body"]
  end

  test "the body endpoint rejects malformed rooms" do
    get "/demos/lexxy/#{"a" * 33}/body"

    assert_response :not_found
  end
end
