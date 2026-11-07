# Finds files embedded in a Yjs update as data: or blob: URLs, such as an
# image src, a map value, or a pasted string. The site accepts no files, so
# the cable refuses an update that carries one (RoomGuarded).
#
# Yjs stores each string in an update as plain UTF-8, so the pattern runs on
# the raw bytes without decoding the update. A URL typed one character at a
# time arrives in pieces and stays plain text, and the img-src CSP keeps any
# data: URL from loading as an image.
module EmbeddedFiles
  PATTERN = %r{data:[a-z]+/[a-z0-9.+-]+[;,]|blob:https?:}in

  def self.in?(bytes) = PATTERN.match?(bytes)
end
