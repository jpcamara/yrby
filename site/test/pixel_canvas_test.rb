require "test_helper"

class PixelCanvasTest < ActiveSupport::TestCase
  test "cells reads the map back from stored state" do
    assert_equal({ "0,0" => 5, "63,63" => 12, "10,20" => 3 }, PixelCanvas.cells(Updates::PIXEL_MAP))
  end

  test "cells is empty with no state and with no map" do
    assert_empty PixelCanvas.cells(nil)
    assert_empty PixelCanvas.cells(Updates::HELLO) # a Y.Text document, no "pixels" root
  end

  test "cells drops entries the page could not have written" do
    assert_equal({ "2,2" => 1 }, PixelCanvas.cells(Updates::PIXEL_MAP_JUNK))
  end

  test "the png is a 512 px indexed image carrying the palette" do
    png = PixelCanvas.png({ "0,0" => 5, "63,63" => 12, "10,20" => 3 })
    chunks = PngReader.chunks(png)

    assert_equal %w[IHDR PLTE IDAT IEND], chunks.keys
    assert_equal [512, 512, 8, 3, 0, 0, 0], chunks["IHDR"].unpack("NNC5")
    assert_equal PixelCanvas::PALETTE.join, chunks["PLTE"].unpack1("H*")
    assert_equal 5, PngReader.index_at(png, 0, 0, scale: 8)
    assert_equal 12, PngReader.index_at(png, 63, 63, scale: 8)
    assert_equal 3, PngReader.index_at(png, 10, 20, scale: 8)
    assert_equal 0, PngReader.index_at(png, 1, 0, scale: 8)
  end

  test "every pixel of a scaled cell carries its index" do
    png = PixelCanvas.png({ "2,3" => 7 })
    scanlines = Zlib::Inflate.inflate(PngReader.chunks(png)["IDAT"])

    assert_equal 512 * 513, scanlines.bytesize
    8.times do |dy|
      8.times do |dx|
        assert_equal 7, scanlines.getbyte((((3 * 8) + dy) * 513) + 1 + (2 * 8) + dx)
      end
    end

    assert_equal 64, scanlines.count("\x07"), "only the one cell is painted"
  end

  test "a blank canvas is all index zero" do
    png = PixelCanvas.png({}, scale: 1)
    scanlines = Zlib::Inflate.inflate(PngReader.chunks(png)["IDAT"])

    assert_equal 64, PngReader.side(png)
    assert_equal "\0" * (64 * 65), scanlines
  end

  test "replay renders one frame per update, last write winning" do
    Updates::PIXEL_PAINTS.each { |update| PixelDocument.append("pixels/room1", update) }

    total, frames = PixelCanvas.replay(Y::Document.locate("pixels/room1"))

    assert_equal 3, total
    assert_equal [0, 1, 2, 3], frames.map(&:after)
    assert_equal 64, PngReader.side(frames[0].png)
    at = ->(frame, x, y) { PngReader.index_at(frame.png, x, y, scale: 1) }

    assert_equal [0, 0], [at[frames[0], 0, 0], at[frames[0], 1, 0]]
    assert_equal [1, 0], [at[frames[1], 0, 0], at[frames[1], 1, 0]]
    assert_equal [1, 2], [at[frames[2], 0, 0], at[frames[2], 1, 0]]
    assert_equal [3, 2], [at[frames[3], 0, 0], at[frames[3], 1, 0]]
  end

  test "replay starts from the compacted snapshot when there is one" do
    Y::Document.create!(key: "pixels/room1", state: Updates::PIXEL_MAP)
    Y::Document.append("pixels/room1", Updates::PIXEL_LATER)

    total, frames = PixelCanvas.replay(Y::Document.locate("pixels/room1"))

    assert_equal 1, total
    assert_equal 12, PngReader.index_at(frames[0].png, 63, 63, scale: 1), "the snapshot is frame 0"
    assert_equal 0, PngReader.index_at(frames[0].png, 5, 5, scale: 1)
    assert_equal 9, PngReader.index_at(frames[1].png, 5, 5, scale: 1)
  end

  test "a long log is sampled to MAX_FRAMES, ending on the last row" do
    300.times { PixelDocument.append("pixels/room1", Updates::PIXEL_PAINTS[0]) }

    total, frames = PixelCanvas.replay(Y::Document.locate("pixels/room1"))

    assert_equal 300, total
    assert_equal PixelCanvas::MAX_FRAMES, frames.size
    assert_equal 0, frames.first.after
    assert_equal 300, frames.last.after
    assert_equal frames.map(&:after), frames.map(&:after).sort.uniq
  end

  test "replay of no document is one blank frame" do
    total, frames = PixelCanvas.replay(nil)

    assert_equal 0, total
    assert_equal [0], frames.map(&:after)
    assert_equal 0, PngReader.index_at(frames[0].png, 0, 0, scale: 1)
  end
end
