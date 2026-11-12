# Moves each room's rendered HTML from the rooms.body column to its Action
# Text body, then drops the column. The HTML goes through NoAttachments.strip
# on the way, like every other write to a rich text on this site.
class MoveRoomBodiesToActionText < ActiveRecord::Migration[8.1]
  # Plain table classes, so the move doesn't depend on Room.
  class LegacyRoom < ActiveRecord::Base
    self.table_name = "rooms"
  end

  class RichText < ActiveRecord::Base
    self.table_name = "action_text_rich_texts"
  end

  def up
    LegacyRoom.reset_column_information
    LegacyRoom.where.not(body: [nil, ""]).find_each do |room|
      RichText.create!(record_type: "Room", record_id: room.id, name: "body",
                       body: NoAttachments.strip(room.body))
    end
    remove_column :rooms, :body
  end

  def down
    add_column :rooms, :body, :text
    LegacyRoom.reset_column_information
    RichText.where(record_type: "Room", name: "body").find_each do |rich_text|
      LegacyRoom.where(id: rich_text.record_id).update_all(body: rich_text.body)
    end
    RichText.where(record_type: "Room", name: "body").delete_all
  end
end
