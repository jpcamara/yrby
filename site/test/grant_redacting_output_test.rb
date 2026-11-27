# frozen_string_literal: true

require "test_helper"
require Rails.root.join("config/grant_redacting_output").to_s

class GrantRedactingOutputTest < ActiveSupport::TestCase
  IDENTIFIER = '{"channel":"LexxyChannel","grant":"eyJfcmFpbHMiOnsi--0123abcd","name":"body"}'

  test "the grant in a logged identifier is blanked out" do
    line = "Unsubscribing from channel: #{IDENTIFIER}"

    assert_equal 'Unsubscribing from channel: {"channel":"LexxyChannel","grant":"[FILTERED]","name":"body"}',
                 GrantRedactingOutput.redact(line)
  end

  test "an identifier escaped inside another JSON string is blanked out too" do
    escaped = IDENTIFIER.to_json

    refute_includes GrantRedactingOutput.redact(escaped), "eyJfcmFpbHMiOnsi"
  end

  test "a logger writing through it never prints the grant" do
    io = StringIO.new
    logger = ActiveSupport::TaggedLogging.logger(GrantRedactingOutput.new(io))
    logger.tagged("req-1") { logger.info("Unsubscribing from channel: #{IDENTIFIER}") }

    refute_includes io.string, "eyJfcmFpbHMiOnsi"
    assert_includes io.string, "[req-1]"
    assert_includes io.string, '"name":"body"'
  end
end
