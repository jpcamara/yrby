# Changelog: yrby-rails

All notable changes to the `yrby-rails` gem (formerly `yrby-actioncable`) are
documented here. The
format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Y::DocumentChannel.authorize_document { |record, name| ... }` runs the
  application's permission check when a client subscribes, on top of the
  signed grant. The block runs in channel context. If it denies access, the
  channel rejects that subscription without opening a stream or serving
  state, and other subscriptions on the connection keep working. Without a
  block, a valid signed grant is enough.

  The check runs once per subscription. Running it on every message would add
  a record load and the application's own queries to every keystroke and
  cursor move. If you revoke a permission mid-session, the change takes effect
  the next time that client subscribes. A short `expires_in:` with a
  `refresh:` URL limits how long that can take, and the application can stop
  the subscription itself when it needs to cut off access immediately. The
  channel stores the decision as channel state, so it survives AnyCable
  creating a new channel instance for each command. A frame that arrives
  without an authorized subscription is rejected even if its grant is valid.
- `record.collaborative_document(name)` returns a bound
  `Y::Collaborative::Attribute`, which both application code and the shipped
  channel use to read and write the document. `y_doc` builds a native
  `Y::Doc`, and `load_state`, `append`, and `key` all use the same storage
  class. `key` and `load_state` don't create a row, but the first `append`
  does. Use `.document_row` for the built-in row operations.
- `Y::Document.key_for(record, name)` returns the conventional key without
  creating a document row.
- `collaborative_sgid(name, expires_in:)` and
  `collaborative_document_tag(record, name, expires_in:, refresh:)` let you
  set the grant lifetime, which used to be GlobalID's default with no way to
  shorten it. `refresh:` is a URL the element fetches when a subscription is
  rejected. That action re-runs the app's authorization and renders
  `{ grant: ... }`, and the client resubscribes the same session with the new
  grant. The client fetches the URL once per rejection and does not poll.

- `Y::DocumentChannel` ships in the gem, so apps don't need to write a
  channel. Clients subscribe with the signed grant the page rendered
  (`{ grant:, name: }`). The channel finds the record from the grant, loads
  the document, and stores changes in `Y::Document`. It rejects grants that
  are missing, tampered with, for the wrong attribute, or for a destroyed
  record.

- `collaborative_document_tag(record, name, **options)` is available in
  Action View through the engine. It renders the mount element with the
  signed grant, the attribute name, and the channel name as data attributes.
  Anyone holding the grant can open the document, the same as with a
  `turbo_stream_from` stream name, so only render the tag on pages where the
  user is allowed to edit the record.

- Channels get `Y::Document` storage by default. Declare `on_load` and
  `on_change` if you want a different store. Outside a yrby-rails app there
  is still no default, and subscribing raises until both hooks are declared.

- `has_collaborative_document :name, encrypted: true` declares which storage
  class backs an attribute, and `Y::DocumentChannel` uses that class. Every
  load and append for an encrypted attribute goes through
  `Y::EncryptedDocument`, so the bytes are ciphertext at rest and the plain
  classes can't read them. The model decides whether an attribute is
  encrypted, and a page or client can't change that. Undeclared attributes use
  plain `Y::Document`.

- `Y::Collaborative` adds signed tokens for record-backed documents, and the
  engine includes it into ActiveRecord::Base. A page creates a token with
  `record.collaborative_sgid(:body)`, and the channel finds the record with
  `Y::Collaborative.locate(params[:grant], :body)`. The token is a signed
  GlobalID scoped to one attribute, so a token for one field can't open
  another. This is the standard way to implement `authorized?` for
  record-backed documents. lexxy-realtime already uses this flow, and now it
  ships in yrby-rails.

### Changed

- **Breaking:** channels reject every subscription until they define
  `authorized?(key)`. `sync_subscribed` now calls it before opening a stream
  or serving state, and the default returns `false`. Add the method to every
  channel that includes `Y::ActionCable`:

  ```ruby
  private

  def authorized?(key)
    current_user&.can_edit?(key)
  end
  ```

  Return `true` for public documents. If the default is what rejected a
  subscription, the log message says so.

- `yrby:install` now creates only the storage migration, since the gem ships
  `Y::DocumentChannel`. Pass `--channel` to also generate an application
  channel for custom authorization or room-keyed documents. That channel
  rejects every subscription until you implement `authorized?`.

### Fixed

- Document elements now attach editors to sessions that exist independently
  of any editor, so pending edits survive navigation under their original
  grant and rejected deliveries can still be recovered. Turbo previews are
  inert, and cached HTML contains no CRDT bytes.
- When an attribute morphs, the element releases the old editor binding and
  acquires the new document. It doesn't move pending edits or authorization
  over to the new document.

- Default storage now supplies the loader and recorder together, and
  declaring only one custom hook raises before subscribing or acknowledging
  an update. Previously, reads and writes silently went to different stores.

- Signed grants work even when the host app doesn't load Active Job.

- The `yrby:tables` migration template caps `y_documents.state` at
  `1.gigabyte - 1` instead of `4.gigabytes - 1`. Postgres raises
  `ArgumentError` for binary limits above 1 GB - 1, so `db:migrate` on a
  fresh Postgres app failed. MySQL maps both values to `longblob`, and
  SQLite ignores limits, so nothing changes there. Apps that already
  migrated are unaffected.

## [0.6.1] - 2026-08-11

### Fixed

- `Y::Document.load_state` serves lossless state (`encode_state_as_update`).
  It previously served gap-free state, so a client joining while a gap was
  open never received the parked edit and could not heal it until its next
  handshake. The quarantined row was always preserved; now the pending
  struct rides along in served state and a mid-gap joiner heals the moment
  the missing dependency arrives.

## [0.6.0] - 2026-08-11

### Changed

- **Causal gaps are now accepted.** A causally-incomplete update, one whose
  causally-prior update the store hasn't seen, is recorded and acked like any
  other (ack-on-durable) instead of being rejected with a resync request,
  and served onward like any other state (a peer parks a pending struct
  exactly as the server does). The gap heals through the ack loop: the
  missing dependency is an update its own sender still holds unacked and
  keeps retransmitting, and join or reconnect handshakes let any client
  that holds it supply it. The write path no longer rebuilds the document
  per update:
  it appends, relays, and acks, so a lost-ack retry records again (replay
  converges; CRDT apply is idempotent).

  This tightens the store contract: `on_load` must preserve pending
  (`encode_state_as_update` or a replayed raw append log), compaction must
  never fold a pending update into a gap-free snapshot and drop the raw
  row (the bundled `Y::Document` quarantines pending rows and folds only
  clean ones), and `on_change` must tolerate duplicate deltas. An acked
  update that leaves durable storage before it integrates is a silent
  data loss.

### Changed (Y::Document)

- Compaction folds past an open gap. A batch holding a causal gap still
  compacts everything integrable: the fold captures every struct that
  integrates, rows independent of the gap included, and only the gap
  tail survives as quarantined raw rows. A healed gap folds out at the
  next compaction. Rows are judged per row against the folded state, so
  a row that causally builds on the gap quarantines with it and an
  acked update never leaves the table before its content is durably in
  state.

### Added

- `on_gap` channel hook: fires with the document key at join/serve time
  whenever the loaded document still holds a causal gap, for metrics on
  unhealed gaps (which no longer surface as resync traffic). An open gap is
  also logged at `info`.

## [0.5.0] - 2026-08-05

### Added

- `Y::EncryptedDocument` / `Y::EncryptedDocumentUpdate`: document storage
  encrypted with Active Record encryption (`state` and update payloads),
  on the same tables; the class you access through decides the
  cryptography, the way `ActionText::EncryptedRichText` does. Point a
  channel's `on_load`/`on_change` (or a record association) at
  `Y::EncryptedDocument` and configure the app's encryption keys. Keep
  one access path per document: rows written encrypted read back as
  ciphertext through the plain classes. Ciphertext is larger than the
  plaintext, so the effective payload cap is roughly three quarters of
  the column limit.

## [0.4.0] - 2026-08-04

### Changed

- **The gem is now `yrby-rails`** (formerly `yrby-actioncable`) and a Rails
  engine. `yrby-actioncable` stops at 0.3.1; `yrby-rails` starts at 0.4.0.
  `Y::ActionCable` keeps its name as the public channel concern.

### Added

- `Y::Document`, engine-owned: a unique transport `key`, an optional
  polymorphic `record` + `name` binding, and the compacted `state`
  snapshot. It stores CRDT state only; derived data (rendered HTML,
  search text) is the application's job. `load_state(key)` /
  `append(key, update)` are the store calls the generated channel uses;
  `locate`/`locate!` find by key.
- `Y::DocumentUpdate`, engine-owned: the uncompacted tail, one delta per
  row, compacted into `state` and deleted at the threshold. A load reads
  the snapshot plus the current tail. Compaction serializes on a
  per-document row lock. Causally-gapped updates
  are quarantined (`pending`), excluded from the compaction trigger, and
  kept until they heal; a healed gap serves immediately and compacts away
  on the next pass.
- `Y::Document.for(record, name)` finds or creates a record's document,
  derives its key (`post/1/body`), and adopts a key-only row already
  holding that key, so a channel writing first and a binding created
  later end up on one row.
- `rails g yrby:tables` creates both tables. It is invoked by
  `yrby:install` and usable directly by gems building on the same
  storage.
- `include Y::ActionCable` now includes `Y::ActionCable::Sync` for you;
  the long spelling keeps working.
- `rails generate yrby:install`: a `DocumentChannel` speaking the
  y-websocket protocol over the gem-owned storage, plus the storage
  migration.
## [0.3.1] - 2026-07-01

### Removed

- The unhealable-gap strike defense that shipped in 0.3.0. That release was
  published prematurely, before the feature had been reviewed; 0.3.1 supersedes
  it with the defense removed while review happens. 0.3.0 remains installable
  and functional; the feature returns in a future release once reviewed.

## [0.3.0] - 2026-07-01

Published prematurely (see 0.3.1): shipped the unhealable-gap strike defense
(settle + drop a repeatedly-gapped update, `{ "ack" => id, "dropped" => true }`,
`gap_strike_limit`, istate-backed strikes under AnyCable) alongside the fixes
below. The fixes carry forward; the defense was withdrawn in 0.3.1 pending
review.

Fixes from a full source review:

### Fixed

- **A lost-ack retry now re-broadcasts.** If the original attempt recorded the
  update and then crashed (or the pub/sub broadcast failed) before
  distributing, the retry was previously settled as `:applied` without
  re-broadcasting; live subscribers stayed stale until their next full resync,
  and nothing else could reach them. The retry now re-broadcasts before acking;
  idempotent CRDT apply makes the duplicate free for every receiver.
- **A missing document key now fails closed.** Under a transport that doesn't
  keep the channel instance alive across actions (AnyCable), an app that forgot
  to pass `key` to `sync_receive` silently recorded updates under a nil key,
  broadcast them to a stream no one subscribes to, and still acked them. The
  frame now raises `Y::Error` instead.

### Changed

- Raised the `yrby` floor to `>= 0.3.1`, whose `update_ready?` is exact
  (trial-integration, not just per-client clocks). With an older core, a
  cross-client-origin gap passed the ready check and the `update_advances?`
  probe then acked-and-dropped real content.

## [0.2.3] - 2026-07-01

### Changed
- Raised the `yrby` floor to `>= 0.3.0`. That release makes
  `Doc#handle_sync_message` answer `SyncStep1` with integrated-only (gap-free)
  state: it no longer serves un-integrable pending structs, which previously
  poisoned peers and drove endless resync traffic. The sync channel serves its
  SyncStep2 response through that method, so with an older core a poisoned server
  store would still hand the gap to clients. No code change here; pinning the
  floor makes gap-free serving self-enforcing instead of dependent on the app
  updating the core gem.

## [0.2.2] - 2026-07-01

### Changed
- Raised the `yrby` floor to `>= 0.2.3`. That release makes `Doc#update_advances?`
  exact for **delete-bearing** updates. The sync channel gates durable
  record-before-distribute on `update_advances?` (`return :applied unless
  doc.update_advances?(update)`), so with an older core a lost-ack retry of a
  deletion the server had already integrated was re-recorded and re-broadcast
  each time. No code change here; pinning the floor just makes the gem's
  exactly-once durable-recording guarantee self-enforcing instead of dependent on
  the app updating the core gem.

## [0.2.1] - 2026-06-29

### Changed
- **Internal:** ActionCable stream-name prefix `y_ruby:` → `yrby:`.
  Server-internal (broadcast + `stream_from` both use it), no public API or
  client-facing wire change. Depends on `yrby >= 0.2.1`.

## [0.2.0] - 2026-06-28

First release. The y-websocket sync channel concern is **`Y::ActionCable::Sync`**,
loaded with `require "y/action_cable"`. Depends on `yrby >= 0.2.0`.

### Notes
- Full y-websocket protocol over ActionCable/AnyCable: origin-filtered relay,
  awareness, on_load/on_save persistence hooks, optional record-before-distribute
  audit mode, and AnyCable `sync_backend :store`.
