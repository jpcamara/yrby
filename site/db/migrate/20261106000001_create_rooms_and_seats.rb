# Rooms replace notes. A room holds one document per demo, so its row
# outlives any one demo's document. Seats are the connections in a room's
# documents, in the database so every server process counts the same ones.
class CreateRoomsAndSeats < ActiveRecord::Migration[8.1]
  def change
    create_table :rooms do |t|
      t.string :slug, null: false, index: { unique: true }
      t.text :body
      t.timestamps
    end

    create_table :seats do |t|
      t.references :room, polymorphic: true, null: false, index: false
      t.string :name, null: false
      t.string :connection_id, null: false, index: true
      t.datetime :seen_at, null: false, index: true
    end
    add_index :seats, %i[room_type room_id name connection_id], unique: true, name: "index_seats_uniqueness"

    drop_table :notes do |t|
      t.string :room, null: false, index: { unique: true }
      t.text :body
      t.timestamps
    end
  end
end
