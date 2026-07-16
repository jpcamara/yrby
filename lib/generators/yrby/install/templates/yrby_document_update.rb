# frozen_string_literal: true

# One CRDT delta (or compacted snapshot) for a collaborative document.
# Rows only accumulate between compactions; see YrbyDocumentStore.
class YrbyDocumentUpdate < ApplicationRecord
end
