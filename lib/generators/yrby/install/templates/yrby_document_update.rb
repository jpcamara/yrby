# frozen_string_literal: true

# One CRDT delta (or compacted snapshot) per row for a collaborative
# document. Y::ActionCable::UpdateLog provides load/append/compact! and
# inline compaction (tune with `self.compact_every = ...`); rows only
# accumulate between compactions.
class <%= model_class_name %> < ApplicationRecord
  include Y::ActionCable::UpdateLog
end
