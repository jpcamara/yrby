# Real Y.js update bytes, so the store and the channel are exercised with frames
# yrby will actually decode rather than random strings. Captured from Y.js the
# same way test/fixtures/yjs_fixtures.rb in the repo root was.
module Updates
  def self.b64(str) = str.unpack1("m0")

  # A Y.Text root named "content" holding "hello world".
  HELLO = b64("AQEBAAQBB2NvbnRlbnQLaGVsbG8gd29ybGQA")

  # Three causally dependent inserts from one client: "A", then "B", then "C".
  # U3 cannot integrate unless U2 has been applied, so applying U1 and U3 alone
  # parks U3 as a pending struct.
  CHAIN = [
    b64("AQEBAAQBB2NvbnRlbnQBQQA="),
    b64("AQEBAYQBAAFCAA=="),
    b64("AQEBAoQBAQFDAA==")
  ].freeze

  # Five independent from-scratch updates from distinct clients. No
  # cross-dependencies, so any order integrates.
  INDEPENDENT = [
    b64("AQEBAAQBB2NvbnRlbnQQY2xpZW50LTEtY29udGVudAA="),
    b64("AQECAAQBB2NvbnRlbnQQY2xpZW50LTItY29udGVudAA="),
    b64("AQEDAAQBB2NvbnRlbnQQY2xpZW50LTMtY29udGVudAA="),
    b64("AQEEAAQBB2NvbnRlbnQQY2xpZW50LTQtY29udGVudAA="),
    b64("AQEFAAQBB2NvbnRlbnQQY2xpZW50LTUtY29udGVudAA=")
  ].freeze

  # A complete awareness frame (client 42, a user and a cursor). Presence is
  # relayed opaquely and never originated by the server, so this is a canned
  # frame rather than something built here.
  AWARENESS_FRAME = b64("AS0BKgEpeyJjdXJzb3IiOnsieCI6MTAsInkiOjIwfSwidXNlciI6ImFsaWNlIn0=")

  # The wire envelope a browser sends: a sync Update frame, base64 in JSON.
  def self.frame(update) = Base64.strict_encode64(Y.wrap_update(update))

  def self.awareness_frame = Base64.strict_encode64(AWARENESS_FRAME)
end
