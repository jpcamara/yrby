# frozen_string_literal: true

# One CRDT delta (or compacted snapshot) per row, belonging to a Y::Document.
# All log behavior — load/append, inline compaction, the pending-gap guard,
# latest_change_at — is Y::UpdateLog.
class Y::DocumentUpdate < ActiveRecord::Base
  self.table_name = "yrby_document_updates"

  belongs_to :document, class_name: "Y::Document"

  include Y::UpdateLog
end
