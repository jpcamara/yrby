# Changelog: yrby-agent

All notable changes to the `yrby-agent` gem are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Y::Agent`, a `Y::Collaborator` with a model. A subclass sets `model` and
  `instructions`, which are RubyLLM::Agent's, and runs from a job. When
  people's typing settles, `changed` asks the model about the blocks they
  changed, in a fresh chat with tools that read the document
  (`read_document`) and edit its blocks (`rewrite_block`, `insert_paragraph`,
  `delete_block`). The tools name blocks by short ids that stay on their
  blocks, and write through `edit`. `ask` asks anything else, and
  `document_tools` picks which tools the model gets.
