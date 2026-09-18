# Reads back the PNGs PixelCanvas writes, enough to assert on them: the
# chunks by type, the image's side, and the palette index at a cell.
module PngReader
  SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  def self.chunks(png)
    raise ArgumentError, "not a PNG" unless png.b.start_with?(SIGNATURE)

    io = StringIO.new(png.b)
    io.read(8)
    chunks = Hash.new { |hash, type| hash[type] = String.new(encoding: Encoding::BINARY) }
    until io.eof?
      length = io.read(4).unpack1("N")
      type = io.read(4)
      chunks[type] << io.read(length)
      io.read(4) # crc
    end
    chunks
  end

  def self.side(png) = chunks(png)["IHDR"].unpack1("N")

  # The palette index at cell (col, row). `scale` is the PNG's pixels per
  # cell. Each scanline is one filter byte then `side` indices.
  def self.index_at(png, col, row, scale:)
    side = side(png)
    scanlines = Zlib::Inflate.inflate(chunks(png)["IDAT"])
    scanlines.getbyte((row * scale * (side + 1)) + 1 + (col * scale))
  end
end
