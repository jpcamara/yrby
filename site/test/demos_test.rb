require "test_helper"

class DemosTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  def start_room(demo = "tiptap", slug = "room1", origin: "http://www.example.com")
    post "/demos/#{demo}/#{slug}/start", headers: { "Origin" => origin }
  end

  def room = Room.find_by!(slug: "room1")

  test "the demo index lists every demo" do
    get "/demos"

    assert_response :success
    Demos::ALL.each { |demo| assert_includes response.body, demo.title }
  end

  test "a demo URL without a room redirects to a new room" do
    get "/demos/tiptap"

    assert_response :redirect
    slug = response.location[%r{/demos/tiptap/(.+)\z}, 1]

    assert Demos.valid_room?(slug), "#{slug.inspect} is not a valid room id"
  end

  test "two visitors get different rooms" do
    get "/demos/tiptap"
    first = response.location
    get "/demos/tiptap"

    assert_not_equal first, response.location
  end

  test "the demo links start a new room" do
    get "/demos"

    assert_includes response.body, %(action="/demos/tiptap/start")
  end

  test "opening a demo starts a new room and goes to it" do
    post "/demos/tiptap/start", headers: { "Origin" => "http://www.example.com" }

    assert_response :see_other
    slug = response.location[%r{/demos/tiptap/(.+)\z}, 1]

    assert Room.exists?(slug: slug)
    post "/demos/tiptap/start", headers: { "Origin" => "http://www.example.com" }

    assert_equal 2, Room.count, "each click gets its own room"
  end

  test "a room nobody started shows a button that starts it" do
    get "/demos/tiptap/room1"

    assert_response :not_found
    assert_includes response.body, "Start the room"
    assert_includes response.body, %(action="/demos/tiptap/room1/start")
  end

  test "many page GETs create no rooms" do
    20.times { |i| get "/demos/lexxy/room#{i}" }

    assert_equal 0, Room.count, "a GET must not create a room"
  end

  test "starting a room creates it and goes to its page" do
    start_room

    assert_response :see_other
    assert_redirected_to "/demos/tiptap/room1"
    assert Room.exists?(slug: "room1")
    assert_equal 0, Y::Document.count, "documents are created by the channel, not the start"
  end

  test "starting a room that exists goes to it" do
    Room.create!(slug: "room1")

    start_room("kanban")

    assert_redirected_to "/demos/kanban/room1"
    assert_equal 1, Room.count
  end

  test "a start from another origin is refused" do
    start_room(origin: "https://evil.example")

    assert_response :forbidden
    assert_equal 0, Room.count
  end

  test "a start at the room cap is refused" do
    Rooms.current = Rooms.new(max_rooms: 1)
    Room.create!(slug: "taken")

    start_room

    assert_response :service_unavailable
    assert_not Room.exists?(slug: "room1")
  end

  test "a start for an unknown demo or a malformed room is a 404" do
    start_room("wiki")

    assert_response :not_found

    start_room("tiptap", "a" * 33)

    assert_response :not_found
    assert_equal 0, Room.count
  end

  test "every demo page renders with its bundle" do
    Room.create!(slug: "room1")

    Demos::ALL.each do |demo|
      get "/demos/#{demo.slug}/room1"

      assert_response :success, "#{demo.slug} did not render"
      assert_includes response.body, "/#{demo.slug}.js"
    end
  end

  test "the lexxy page names its document key" do
    Room.create!(slug: "room1")

    get "/demos/lexxy/room1"

    # collaborative_rich_textarea names the client-side Yjs binding in
    # <lexxy-collaboration doc-id>. The server never sees it.
    assert_includes response.body, %(doc-id="room-#{room.id}-body")
  end

  test "every shape demo page renders a yrby-document for the room document" do
    Room.create!(slug: "room1")

    Demos.shape_slugs.each do |slug|
      get "/demos/#{slug}/room1"

      element = Nokogiri::HTML5(response.body).at_css("yrby-document")

      assert element, "#{slug} page has no yrby-document"
      assert_equal "RoomChannel", element["channel"]
      assert_equal slug, element["name"]
      # The element subscribes to RoomChannel with this grant and name, and the
      # grant resolves to this room for this demo's document only.
      assert_equal room, Y::Collaborative.locate(element["grant"], slug), "#{slug} page has no grant for the room"
      assert_nil Y::Collaborative.locate(element["grant"], "body")
    end
  end

  test "the lexxy page renders the room's grant for the body field" do
    Room.create!(slug: "room1")

    get "/demos/lexxy/room1"

    element = response.body[/<yrby-document [^>]+>/]

    assert_includes element, %(name="body")
    assert_includes element, %(channel="LexxyChannel")
    grant = element[/grant="([^"]+)"/, 1]

    assert_equal room, GlobalID::Locator.locate_signed(grant, for: LexxyRealtime.grant_purpose("body"))
  end

  test "a demo page is not cached" do
    get "/demos/tiptap/room1"

    assert_equal "no-store", response.headers["cache-control"]
  end

  test "the demo page includes the room link and the second window button" do
    Room.create!(slug: "room1")

    get "/demos/kanban/room1"

    assert_includes response.body, "http://www.example.com/demos/kanban/room1"
    assert_includes response.body, "second-window"
  end

  test "the nav keeps the room across demos" do
    Room.create!(slug: "room1")

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

  test "the lexxy editor mounts with attachments disabled" do
    Room.create!(slug: "room1")

    get "/demos/lexxy/room1"

    assert_includes response.body, %(attachments="false")
  end

  test "the body endpoint returns the stored Action Text HTML" do
    Room.create!(slug: "room1", body: "<h1>from Ruby</h1>")

    get "/demos/lexxy/room1/body"

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    assert_equal({ "body" => "<h1>from Ruby</h1>" }, response.parsed_body)
  end

  test "the body endpoint returns nil for a room that doesn't exist" do
    get "/demos/lexxy/nothere/body"

    assert_response :success
    assert_nil response.parsed_body["body"]
  end

  test "the body endpoint rejects malformed rooms" do
    get "/demos/lexxy/#{"a" * 33}/body"

    assert_response :not_found
  end

  # --- the shape demos' server-side read (DemosController#stored) ------------

  def store(demo, update)
    Room.find_or_create_by!(slug: "room1").collaborative_document(demo).append(update)
  end

  test "the stored endpoint reads a Y.Text demo back as a string" do
    store(:codemirror, Updates::CODE_TEXT)

    get "/demos/codemirror/room1/stored"

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    assert_equal "const x = 1", response.parsed_body["body"]
  end

  test "the stored endpoint reads a Y.XmlFragment demo back as block text" do
    store(:tiptap, Updates::PROSEMIRROR_DEFAULT)

    get "/demos/tiptap/room1/stored"

    assert_response :success
    assert_equal "<paragraph>hello</paragraph>", response.parsed_body["body"]
  end

  test "the stored endpoint reads a Y.Map demo back as JSON" do
    store(:whiteboard, Updates::SHAPES_MAP)

    get "/demos/whiteboard/room1/stored"

    assert_response :success
    assert_equal(
      { "n1" => { "text" => "drag me", "x" => 40, "y" => 40 } },
      JSON.parse(response.parsed_body["body"])
    )
  end

  test "the stored endpoint reads a form field held in a Y.Text as a string" do
    store(:form, Updates::FORM_MAP)

    get "/demos/form/room1/stored"

    assert_response :success
    assert_equal(
      { "name" => "Ada Lovelace", "role" => "Engineer" },
      JSON.parse(response.parsed_body["body"])
    )
  end

  test "the stored endpoint reads a Y.Array demo back as JSON" do
    store(:kanban, Updates::CARDS_ARRAY)

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

  test "the stored endpoint reads chat messages with their reactions per person" do
    store(:chat, Updates::MESSAGES_ARRAY)

    get "/demos/chat/room1/stored"

    assert_response :success
    message = JSON.parse(response.parsed_body["body"]).sole

    assert_equal "hi", message["text"]
    assert_equal({ "p1" => "❤️", "p2" => "👍" }, message["reactions"])
  end

  test "the stored endpoint sorts keys in nested objects" do
    store(:spreadsheet, Updates::ROWS_ARRAY)

    get "/demos/spreadsheet/room1/stored"

    assert_response :success
    # Keys are sorted at every depth so the output is the same every time.
    assert_equal %([{"item":"Chairs","qty":"4"}]), response.parsed_body["body"]
  end

  test "the stored endpoint returns nil for a room with no document" do
    Room.create!(slug: "room1")

    get "/demos/kanban/room1/stored"

    assert_response :success
    assert_nil response.parsed_body["body"]
  end

  test "the stored endpoint returns nil for a room that doesn't exist" do
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
    Room.create!(slug: "room1")

    get "/demos/kanban/room1/stored"

    assert_response :success
    assert_equal 0, Y::Document.count, "a read must not create a row"
  end
end
