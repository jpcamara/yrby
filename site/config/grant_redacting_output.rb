# frozen_string_literal: true

# The log's output, with grants blanked out. A grant opens a document to
# whoever holds it, and Action Cable logs a subscription's identifier, grant
# included, when it unsubscribes ("Unsubscribing from channel: {...}"). Rails
# has no setting for that line, so production writes its log through this.
#
# A plain require, like limits.rb, because production.rb builds the logger
# before autoloading is available.
class GrantRedactingOutput
  # "grant":"..." in an identifier, also when the identifier is itself a JSON
  # string inside another one (\"grant\":\"...\").
  GRANT = /(\\?"grant\\?"\s*:\s*\\?")[^"\\]+/

  def self.redact(text) = text.gsub(GRANT, '\1[FILTERED]')

  def initialize(io)
    @io = io
  end

  def write(*strings) = @io.write(*strings.map { |string| self.class.redact(string.to_s) })

  def close = @io.close
end
