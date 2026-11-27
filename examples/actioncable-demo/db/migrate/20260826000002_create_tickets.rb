# frozen_string_literal: true

# The record behind the yrby-forms demo page: one column per field tier the
# gem detects (enum, integer, boolean, date, string, text).
class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.string :title
      t.string :status, null: false, default: "triage"
      t.integer :priority
      t.boolean :urgent
      t.date :due_on
      t.string :summary
      t.text :description
      t.timestamps
    end
  end
end
