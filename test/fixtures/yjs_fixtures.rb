# frozen_string_literal: true

# Y.js Test Fixtures for yrb-lite
# Generated from yjs version 13.6.29
# Regenerate with: bun run test/fixtures/generate_fixtures.mjs

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
end
