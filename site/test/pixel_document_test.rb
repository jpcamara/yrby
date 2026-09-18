require "test_helper"

class PixelDocumentTest < ActiveSupport::TestCase
  test "the pixel document keeps every row where Y::Document compacts" do
    65.times { Y::Document.append("kanban/room1", Updates::PIXEL_PAINTS[0]) }
    65.times { PixelDocument.append("pixels/room1", Updates::PIXEL_PAINTS[0]) }

    compacted = Y::Document.locate("kanban/room1")

    assert_operator compacted.updates.count, :<, 65
    assert_not_nil compacted.state

    kept = Y::Document.locate("pixels/room1")

    assert_equal 65, kept.updates.count
    assert_nil kept.state
  end

  test "a pixel document is an ordinary Y::Document row to the rest of the site" do
    PixelDocument.append("pixels/room1", Updates::PIXEL_PAINTS[0])

    assert_equal 1, Y::Document.count
    assert_equal({ "0,0" => 1 }, PixelCanvas.cells(Y::Document.load_state("pixels/room1")))
  end
end
