# frozen_string_literal: true

# One CRDT delta per row: the document's uncompacted tail, compacted into
# Y::Document#state and deleted at the compaction threshold. pending marks a
# causally-gapped row, quarantined until its dependency arrives.
class Y::DocumentUpdate < ActiveRecord::Base
  self.table_name = "y_document_updates"

  belongs_to :document, class_name: "Y::Document"
end
