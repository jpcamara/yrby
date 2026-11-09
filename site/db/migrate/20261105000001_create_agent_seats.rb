# frozen_string_literal: true

# AgentSeats' state, shared by the web server and the job processes: one row
# per agent in a room, and one row per day counting the agents' model calls.
class CreateAgentSeats < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_seats do |t|
      t.string :room, null: false
      t.string :owner, null: false
      t.datetime :created_at, null: false
      t.index %i[room owner], unique: true
    end

    create_table :agent_call_days, primary_key: :day, id: :date do |t|
      t.integer :calls, null: false, default: 0
    end
  end
end
