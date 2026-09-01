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

  test "every shape demo page hands the client a signed document grant" do
    Demos::ALL.reject { |d| d.slug == "lexxy" }.each do |demo|
      get "/demos/#{demo.slug}/room1"

      token = response.body[/data-token="([^"]+)"/, 1]

      assert_predicate token, :present?, "#{demo.slug} page carries no token"
      # The token IS the subscription: it verifies to exactly this document key,
      # the same access model the lexxy page's Note token gives.
      assert_equal "#{demo.slug}/room1", Demos.verified_key(token)
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

  test "the lexxy page creates no note and hands the client a field-scoped room token" do
    get "/demos/lexxy/room1"

    assert_response :success
    # The GET is anonymous and uncapped, so it must not mint a row: a crawler
    # fetching room URLs would otherwise create Notes without bound.
    assert_equal 0, Note.count, "the page must not create the note on a GET"
    assert_equal 0, Y::Document.count

    token = response.body[/data-token="([^"]+)"/, 1]

    assert_predicate token, :present?
    # The token verifies to this room under the body-scoped purpose...
    assert_equal "room1", Note.verified_room(token, "body")
    # ...and not under any other field, the same field scoping the gem's sgid gives.
    assert_nil Note.verified_room(token, "title")
    assert_includes response.body, %(data-field="body")
  end

  test "many lexxy page GETs create zero notes" do
    20.times { |i| get "/demos/lexxy/room#{i}" }

    assert_equal 0, Note.count, "GETs must never mint note rows"
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

  # --- the shape demos' server-side read (DemosController#stored) ------------

  test "the stored endpoint reads a Y.Text demo back as a string" do
    Y::Document.append("codemirror/room1", Updates::CODE_TEXT)

    get "/demos/codemirror/room1/stored"

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    assert_equal "const x = 1", response.parsed_body["body"]
  end

  test "the stored endpoint reads a Y.XmlFragment demo back as block text" do
    Y::Document.append("tiptap/room1", Updates::PROSEMIRROR_DEFAULT)

    get "/demos/tiptap/room1/stored"

    assert_response :success
    assert_equal "<paragraph>hello</paragraph>", response.parsed_body["body"]
  end

  test "the stored endpoint reads a Y.Map demo back as JSON" do
    Y::Document.append("whiteboard/room1", Updates::SHAPES_MAP)

    get "/demos/whiteboard/room1/stored"

    assert_response :success
    assert_equal(
      { "n1" => { "text" => "drag me", "x" => 40, "y" => 40 } },
      JSON.parse(response.parsed_body["body"])
    )
  end

  test "the stored endpoint reads a Y.Array demo back as JSON" do
    Y::Document.append("kanban/room1", Updates::CARDS_ARRAY)

    get "/demos/kanban/room1/stored"

    assert_response :success
    assert_equal(
      [
        { "id" => "1", "text" => "Design the API", "column" => "todo" },
        { "id" => "2", "text" => "Ship it", "column" => "done" }
      ],
      JSON.parse(response.parsed_body["body"])
    )
  end

  test "the stored endpoint keys nested object output stably (sorted)" do
    Y::Document.append("spreadsheet/room1", Updates::ROWS_ARRAY)

    get "/demos/spreadsheet/room1/stored"

    assert_response :success
    # Sorted keys at every depth, so the panel and any diff are deterministic.
    assert_equal %([{"item":"Chairs","qty":"4"}]), response.parsed_body["body"]
  end

  test "the stored endpoint is empty-safe for a room with no document" do
    get "/demos/kanban/nothere/stored"

    assert_response :success
    assert_nil response.parsed_body["body"]
  end

  test "the stored endpoint 404s for the lexxy demo, which uses body instead" do
    get "/demos/lexxy/room1/stored"

    assert_response :not_found
  end

  test "the stored endpoint rejects unknown demos and malformed rooms" do
    get "/demos/wiki/room1/stored"
    assert_response :not_found

    get "/demos/kanban/#{"a" * 33}/stored"
    assert_response :not_found
  end

  test "the stored endpoint does not create a document" do
    get "/demos/kanban/room1/stored"

    assert_response :success
    assert_equal 0, Y::Document.count, "a read must not mint a row"
  end
end
