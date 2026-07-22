# frozen_string_literal: true

# One CRDT delta (or compacted snapshot) for a collaborative document.
# Rows only accumulate between compactions; see <%= store_class_name %>.
class <%= model_class_name %> < ApplicationRecord
end
