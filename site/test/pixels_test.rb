require "test_helper"

class PixelsTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  def frame_png(frame) = Base64.strict_decode64(frame["png"].delete_prefix("data:image/png;base64,"))

  test "the pixels page carries the palette, the canvas, and both Ruby panels" do
    get "/demos/pixels/room1"

    assert_response :success
    assert_includes response.body, %(data-document-key="pixels/room1")
    assert_equal PixelCanvas::PALETTE.size, response.body.scan(%(class="swatch")).size
    assert_includes response.body, %(id="pixel-canvas" width="64" height="64")
    assert_includes response.body, "/demos/pixels/room1/canvas.png"
    assert_includes response.body, "/demos/pixels/room1/timelapse"
  end

  test "the png endpoint renders the stored canvas in Ruby" do
    Y::Document.append("pixels/room1", Updates::PIXEL_MAP)

    get "/demos/pixels/room1/canvas.png"

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "no-store", response.headers["cache-control"]
    assert_equal 512, PngReader.side(response.body)
    assert_equal 5, PngReader.index_at(response.body, 0, 0, scale: 8)
    assert_equal 12, PngReader.index_at(response.body, 63, 63, scale: 8)
    assert_equal 3, PngReader.index_at(response.body, 10, 20, scale: 8)
  end

  test "the png endpoint renders a blank canvas for a room with no document" do
    get "/demos/pixels/nothere/canvas.png"

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal 0, PngReader.index_at(response.body, 0, 0, scale: 8)
    assert_equal 0, Y::Document.count, "a read must not mint a row"
  end

  test "the timelapse replays the update log as frames" do
    Updates::PIXEL_PAINTS.each { |update| PixelDocument.append("pixels/room1", update) }

    get "/demos/pixels/room1/timelapse"

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    body = response.parsed_body

    assert_equal 3, body["updates"]
    assert_equal [0, 1, 2, 3], body["frames"].pluck("after")
    first = frame_png(body["frames"].first)
    last = frame_png(body["frames"].last)

    assert_equal 64, PngReader.side(last)
    assert_equal 0, PngReader.index_at(first, 0, 0, scale: 1)
    assert_equal 3, PngReader.index_at(last, 0, 0, scale: 1)
    assert_equal 2, PngReader.index_at(last, 1, 0, scale: 1)
  end

  test "the timelapse is empty-safe and creates nothing" do
    get "/demos/pixels/nothere/timelapse"

    assert_response :success
    assert_equal 0, response.parsed_body["updates"]
    assert_equal [0], response.parsed_body["frames"].pluck("after")
    assert_equal 0, Y::Document.count
  end

  test "both endpoints reject a malformed room" do
    get "/demos/pixels/#{"a" * 33}/canvas.png"

    assert_response :not_found

    get "/demos/pixels/#{"a" * 33}/timelapse"

    assert_response :not_found
  end
end
