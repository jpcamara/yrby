# frozen_string_literal: true

# The yrby-forms demo record. Tier detection: status (enum), priority
# (integer), urgent (boolean), and due_on (date) are LWW map entries;
# summary (string) and description (text) are Y.Text shares. One
# Y::Document named "fields" holds the whole set. The enum comes first:
# detection reads defined_enums when the macro runs.
class Ticket < ApplicationRecord
  enum :status, { triage: "triage", active: "active", done: "done" }

  has_collaborative_fields :status, :priority, :urgent, :due_on, :summary, :description
end
