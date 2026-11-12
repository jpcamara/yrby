# The tools a board agent's model works the board with. Each write goes
# through the agent, which moves its cursor to the item, writes it inside its
# edit, and waits a moment, so people watch every change land.
module BoardTools
  ITEM = {
    type: "object",
    properties: {
      ref: { type: "string",
             description: "Your own name for this item, so later items in the same call can connect to it" },
      type: { type: "string", enum: BoardSpec::TYPES },
      x: { type: "number", description: "Left edge, board units" },
      y: { type: "number", description: "Top edge, board units" },
      w: { type: "number",
           description: "Width. Defaults: note 200 (180 with an icon or drawing), text 360, shape 160, " \
                        "frame 640, sticker 80" },
      h: { type: "number",
           description: "Height. Defaults: note 132 (200 with an icon or drawing), text 40, shape 90, " \
                        "frame 420, sticker 80" },
      title: { type: "string", description: "A note's first line" },
      caption: { type: "string", description: "A note's smaller second line" },
      text: { type: "string", description: "A text item's words, or a shape's or frame's label" },
      color: { type: "string", description: "yellow, blue, pink, green, purple, orange, or #rrggbb. " \
                                            "Paths default to dark ink; give a road a warm color like #f4a261" },
      icon: { type: "string", description: "One emoji, drawn as a full-color illustration. On a note it fills " \
                                           "the top, above the words; a sticker is just the picture" },
      drawing: { type: "string", description: "A note's or sticker's custom illustration: what to draw, in a few " \
                                              "words (\"a huckleberry pie\", \"a delivery truck on a road\"). It's " \
                                              "drawn in the background and replaces the icon when ready, so give " \
                                              "an icon too" },
      shape: { type: "string", enum: BoardSpec::SHAPES },
      size: { type: "number", description: "A text item's font size, 12 to 72" },
      align: { type: "string", enum: %w[left center right] },
      from: { type: "string", description: "A connector's start: an item id, or a ref from this call" },
      to: { type: "string", description: "A connector's end: an item id, or a ref from this call" },
      arrow: { type: "boolean", description: "false for a connector with no arrowhead, such as a note's tie " \
                                             "to its milestone" },
      dash: { type: "boolean", description: "Dashed line, for a connector or path" },
      stroke: { type: "number", description: "A path's line width, 1 to 28" },
      points: { type: "array", items: { type: "array", items: { type: "number" } },
                description: "A path's points, [[x, y], ...] in board units" }
    },
    required: %w[type]
  }.freeze

  CHANGE = {
    type: "object",
    properties: ITEM[:properties].except(:ref, :type, :from, :to, :points)
                                 .merge(id: { type: "string", description: "The item's id" }),
    required: %w[id]
  }.freeze

  def self.all(agent) = [LookAtBoard, AddItems, UpdateItems, DeleteItems, SetTitle].map { |tool| tool.new(agent) }

  class Tool < RubyLLM::Tool
    def self.tool_name = name.split("::").last.gsub(/(?<=[a-z])(?=[A-Z])/, "_").downcase

    def initialize(agent)
      super()
      @agent = agent
    end

    # Any failure goes back to the model as an error it can fix
    # (BoardSteps#tool_failed). Stopping and giving up still end the ask.
    def call(tool_call: nil, **arguments)
      Rails.logger.info("#{self.class.tool_name} #{arguments.to_json[0, 4000]}")
      @agent.place_drawings
      super(tool_call:, **arguments.transform_values { |value| decode(value) })
    rescue AgentModel::Stopped, AgentModel::Error
      raise
    rescue JSON::ParserError => e
      @agent.tool_failed("Your arguments weren't valid JSON (#{e.message[0, 120]}). Send them again as plain " \
                         "JSON, not inside a string.")
    rescue StandardError => e
      Rails.logger.warn("#{self.class.tool_name} failed: #{e.class}: #{e.message}")
      @agent.tool_failed("That call failed (#{e.message[0, 200]}). Fix it and try again, or skip it.")
    end

    private

    # Some models send an array or object argument as a JSON string, or a
    # list of JSON strings. Decode those so the tool gets what it declared.
    # A whole argument that doesn't parse raises, and Tool#call sends it back;
    # a string inside one, such as a note titled "[Draft]", stays text.
    def decode(value, whole: true)
      case value
      when Array then value.map { |each| decode(each, whole: false) }
      when /\A\s*[\[{]/ then decode(JSON.parse(value), whole: false)
      else value
      end
    rescue JSON::ParserError
      raise if whole

      value
    end
  end

  class LookAtBoard < Tool
    description "Lists everything on the board now, one item per line: id, type, x, y, w, h, color, icon, and text. " \
                "People keep editing while you work, so look again before changing what they might have moved."

    def execute = @agent.board_listing
  end

  class AddItems < Tool
    description "Adds items to the board, drawn one at a time in the order given. Returns each new item's id. " \
                "Frames always sit under the other items. Add many items per call."
    parameters(type: "object", properties: { items: { type: "array", items: ITEM } }, required: %w[items])

    def execute(items:) = @agent.add_items(Array(items))
  end

  class UpdateItems < Tool
    description "Changes existing items: move or resize them (x, y, w, h), or change their words, color, icon, " \
                "drawing, shape, size, or dash. Give only the fields to change."
    parameters(type: "object", properties: { changes: { type: "array", items: CHANGE } }, required: %w[changes])

    def execute(changes:) = @agent.update_items(Array(changes))
  end

  class DeleteItems < Tool
    description "Removes items from the board by id. Connectors attached to them go too."
    parameters(type: "object", properties: { ids: { type: "array", items: { type: "string" } } }, required: %w[ids])

    def execute(ids:) = @agent.delete_items(Array(ids))
  end

  class SetTitle < Tool
    description "Sets the board's title and subtitle, at the top of everyone's screen."
    parameter :title, description: "A short title"
    parameter :subtitle, description: "One line under it", required: false

    def execute(title:, subtitle: "") = @agent.set_title(title, subtitle)
  end
end
