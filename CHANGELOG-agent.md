# Changelog: yrby-agent

All notable changes to the `yrby-agent` gem are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The first release. Everything here is experimental and may change in any
release. See [docs/experimental.md](docs/experimental.md).

### Added

- `Y::ActionCable::Client` joins a document over the cable's websocket with a
  grant, as a browser does. `edit` sends a change, every update is resent
  until acked, and a dropped socket reconnects. `presence=` shows the client
  to others and renews itself, and answers presence from a client it hasn't
  seen with its own, so a newcomer sees it without waiting for a renewal.
  It sends the URL's origin, and `headers:` add anything else the
  connection checks.
- `Y::Collaborator` takes part in a document the way a person does, from a
  job or anywhere else. A subclass defines `joined` and `changed(blocks)`,
  where an AI agent calls its model, and sets `self.presence =`.
  `Reviewer.run(post.collaborative_document(:body), url:, headers:)` joins
  with a grant, calls `changed` with live handles to the blocks people
  changed once their typing settles, and returns when nobody else has been
  present for `idle` seconds, after `max_stay`, or on `leave`. One
  collaborator works on a document at a time, through a lock in
  `Rails.cache`, or one per person with `as: person`. An error in `joined`
  or `changed` ends the collaborator and raises out of `run`.
  `require "y/collaborator"` to use it.
- `Y::Agent`, a `Y::Collaborator` with a model. A subclass sets `model` and
  `instructions`, which are RubyLLM::Agent's, and runs from a job. When
  people's typing settles, `changed` asks the model about the blocks they
  changed, in a fresh chat with tools that read the document
  (`read_document`) and edit its blocks (`rewrite_block`, `insert_paragraph`,
  `delete_block`). The tools name blocks by short ids that stay on their
  blocks, and write through `edit`. `ask` asks anything else, and
  `document_tools` picks which tools the model gets.
