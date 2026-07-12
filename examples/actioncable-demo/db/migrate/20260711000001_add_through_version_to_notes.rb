# frozen_string_literal: true

# The store version (highest change id / log size) the note's content was
# rendered through — the one-integer staleness check behind freshen-on-read
# (see NoteMaterializer).
class AddThroughVersionToNotes < ActiveRecord::Migration[8.1]
  def change
    add_column :notes, :through_version, :bigint, null: false, default: 0
  end
end
