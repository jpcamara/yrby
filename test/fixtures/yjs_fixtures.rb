# frozen_string_literal: true

# Y.js Test Fixtures for yrby, static bytes captured from the real Y.js
# library so the Ruby/Rust port can be tested for byte-level interop.
# Regenerate with: bun run test/fixtures/generate_fixtures.mjs > test/fixtures/yjs_fixtures.rb

module YjsFixtures
  def self.b64(str)
    str.unpack1("m0")
  end

  # Fixture 1: Text with 'hello world' (client_id=1, field='content')
  module TextHelloWorld
    CLIENT_ID = 1
    UPDATE = YjsFixtures.b64("AQEBAAQBB2NvbnRlbnQLaGVsbG8gd29ybGQA")
    STATE_VECTOR = YjsFixtures.b64("AQEL")
  end

  # Fixture 2: Two docs merged
  # doc1 (client_id=1): content = "from doc1"
  # doc2 (client_id=2): content = "from doc2"
  module TwoDocsMerged
    DOC1_UPDATE = YjsFixtures.b64("AQEBAAQBB2NvbnRlbnQJZnJvbSBkb2MxAA==")
    DOC2_UPDATE = YjsFixtures.b64("AQECAAQBB2NvbnRlbnQJZnJvbSBkb2MyAA==")
    MERGED_UPDATE = YjsFixtures.b64("AgECAAQBB2NvbnRlbnQJZnJvbSBkb2MyAQEABAEHY29udGVudAlmcm9tIGRvYzEA")
    MERGED_STATE_VECTOR = YjsFixtures.b64("AgIJAQk=")
  end

  # Fixture 3: Sync protocol test
  # doc1 (client_id=1): content = "synced content"
  # doc2 (client_id=2): empty, then synced
  module SyncProtocol
    INITIAL_SV_DOC2 = YjsFixtures.b64("AA==")
    DIFF_UPDATE = YjsFixtures.b64("AQEBAAQBB2NvbnRlbnQOc3luY2VkIGNvbnRlbnQA")
    FINAL_SV = YjsFixtures.b64("AQEO")
  end

  # Fixture 4: Empty doc baseline
  module EmptyDoc
    STATE_VECTOR = YjsFixtures.b64("AA==")
    UPDATE = YjsFixtures.b64("AAA=")
  end

  # Fixture 5: three causally-dependent updates from one client, insert "A",
  # then "B", then "C". Each update references the previous item, so U3 cannot
  # integrate unless U2 has been applied first (it parks as a pending struct).
  module CausalChain
    U1 = YjsFixtures.b64("AQEBAAQBB2NvbnRlbnQBQQA=")
    U2 = YjsFixtures.b64("AQEBAYQBAAFCAA==")
    U3 = YjsFixtures.b64("AQEBAoQBAQFDAA==")
  end

  # Fixture 6: five independent, from-scratch updates from distinct clients
  # (1..5). No cross-dependencies, so any receive order integrates; applying all
  # five converges to a state vector covering all five clients. Used by the
  # store-backed concurrency specs.
  module ConcurrentClients
    FIVE = [
      YjsFixtures.b64("AQEBAAQBB2NvbnRlbnQQY2xpZW50LTEtY29udGVudAA="),
      YjsFixtures.b64("AQECAAQBB2NvbnRlbnQQY2xpZW50LTItY29udGVudAA="),
      YjsFixtures.b64("AQEDAAQBB2NvbnRlbnQQY2xpZW50LTMtY29udGVudAA="),
      YjsFixtures.b64("AQEEAAQBB2NvbnRlbnQQY2xpZW50LTQtY29udGVudAA="),
      YjsFixtures.b64("AQEFAAQBB2NvbnRlbnQQY2xpZW50LTUtY29udGVudAA=")
    ].freeze
  end

  # Fixture 7: a valid awareness (presence) message frame, client 42 with a
  # user + cursor. The server only ever relays such frames opaquely
  # (message_kind => 3); it never originates presence. So tests use this canned
  # frame instead of generating one server-side.
  module Presence
    FRAME = YjsFixtures.b64("AS0BKgEpeyJjdXJzb3IiOnsieCI6MTAsInkiOjIwfSwidXNlciI6ImFsaWNlIn0=")
  end
end
