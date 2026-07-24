# frozen_string_literal: true

# One CRDT delta (or compacted snapshot) per row for a collaborative
# document. Y::UpdateLog provides load/append/compact! and inline compaction
# (tune with `self.compact_every = ...`); rows only accumulate between
# compactions.
#
# Keys are whatever strings your channel authorizes — yrby doesn't know what
# they mean, so it can't clean up after them. When the resource behind a key
# goes away, delete its rows (e.g. from that model's destroy callback):
#
#   <%= model_class_name %>.where(document_key: key).delete_all
class <%= model_class_name %> < ApplicationRecord
  include Y::UpdateLog
end
