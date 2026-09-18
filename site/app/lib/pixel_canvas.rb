require "zlib"

# The pixel canvas demo's server side: the grid, the palette, and the two
# things Ruby does with the document that the browser does not. It renders
# the current canvas as a PNG, and it replays the canvas from the stored
# update rows. Both start from read_map, the same call the stored panel makes.
module PixelCanvas
  SIZE = 64
  ROOT = "pixels".freeze

  # r/place's 2017 palette. Index 0 is an unpainted cell.
  PALETTE = %w[
    ffffff e4e4e4 888888 222222 ffa7d1 e50000 e59500 a06a42
    e5d900 94e044 02be01 00d3dd 0083c7 0000ea cf6ee4 820080
  ].freeze

  # Pixels per cell in the PNG endpoint's image: 64 cells become 512 px, a
  # size link previews accept.
  SCALE = 8

  # The most frames a timelapse carries. Past this many updates the log is
  # sampled evenly, so a long history still fits in one response.
  MAX_FRAMES = 120

  # A cell key as the page writes it: two grid coordinates.
  CELL = /\A(\d{1,2}),(\d{1,2})\z/

  SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  Frame = Data.define(:after, :png)

  class << self
    # The cells of a stored state: {"x,y" => palette index}. A key or value
    # the page could not have written (off the grid, past the palette) is
    # dropped rather than rendered.
    def cells(state)
      return {} if state.nil?

      doc = Y::Doc.new
      doc.apply_update(state)
      cells_of(doc)
    end

    def cells_of(doc)
      json = doc.read_map(ROOT)
      return {} if json.nil?

      JSON.parse(json).select { |key, index| cell?(key, index) }
    end

    # An indexed-color PNG of the cells, written by hand. The format is a
    # signature and four chunks: the header, the palette, one zlib stream of
    # scanlines (each prefixed with filter type 0), and the end marker.
    def png(cells, scale: SCALE)
      rows = Array.new(SIZE) { Array.new(SIZE, 0) }
      cells.each do |key, index|
        x, y = key.split(",").map(&:to_i)
        rows[y][x] = index
      end
      side = SIZE * scale
      scanlines = rows.each_with_object(String.new(encoding: Encoding::BINARY)) do |row, out|
        line = row.map { |index| index.chr * scale }.join
        scale.times { out << "\0" << line }
      end

      [
        SIGNATURE,
        chunk("IHDR", [side, side, 8, 3, 0, 0, 0].pack("NNC5")),
        chunk("PLTE", PALETTE.pack("H6" * PALETTE.size)),
        chunk("IDAT", Zlib::Deflate.deflate(scanlines)),
        chunk("IEND", "")
      ].join
    end

    # The canvas replayed from a document's stored rows. The compacted
    # snapshot, if there is one, is frame 0; the update log is then applied
    # row by row in the order the server recorded it. Returns the row count
    # and the sampled frames, each a 1:1 PNG. No document replays as one
    # blank frame.
    def replay(document)
      payloads = document ? document.updates.order(:id).pluck(:payload) : []
      doc = Y::Doc.new
      doc.apply_update(document.state) if document&.state
      keep = frame_marks(payloads.size)

      frames = [Frame.new(after: 0, png: png(cells_of(doc), scale: 1))]
      payloads.each_with_index do |payload, i|
        doc.apply_update(payload)
        frames << Frame.new(after: i + 1, png: png(cells_of(doc), scale: 1)) if keep.include?(i + 1)
      end
      [payloads.size, frames]
    end

    private

    def cell?(key, index)
      return false unless index.is_a?(Integer) && index.between?(0, PALETTE.size - 1)

      match = CELL.match(key)
      !match.nil? && match[1].to_i < SIZE && match[2].to_i < SIZE
    end

    # Which update counts get a frame: every one while the log is short,
    # otherwise MAX_FRAMES - 1 evenly spaced counts ending on the last row.
    def frame_marks(total)
      slots = MAX_FRAMES - 1
      return (1..total).to_set if total <= slots

      (1..slots).to_set { |k| (k * total.fdiv(slots)).round }
    end

    def chunk(type, data)
      [[data.bytesize].pack("N"), type, data, [Zlib.crc32(type + data)].pack("N")].join
    end
  end
end
