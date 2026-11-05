# frozen_string_literal: true

module Y
  class Agent < Collaborator
    # The RubyLLM tools an agent gives its model. The model names blocks by
    # the ids read_document lists, and every write goes through the agent's
    # `edit`, so it reaches people as the model makes it.
    module Tools
      # `blocks` as the model reads them: one line per block, "b3 (paragraph): text".
      def self.listing(agent, blocks)
        blocks.map do |block|
          kind = block.attributes.values_at("__type", "__tag").compact.join(" ")
          "#{agent.block_id(block)} (#{kind}): #{block.text}"
        end.join("\n")
      end

      class Tool < RubyLLM::Tool
        def self.tool_name = name.split("::").last.gsub(/(?<=[a-z])(?=[A-Z])/, "_").downcase

        def initialize(agent)
          super()
          @agent = agent
        end

        private

        def missing(id) = { error: "There's no block #{id}. Call read_document for the blocks there are now." }
      end

      class ReadDocument < Tool
        description "Lists the document's blocks in order, one per line, as `id (type): text`. " \
                    "Name a block by its id in the other tools. Ids stay on their blocks while people edit."

        def execute
          blocks = @agent.document_blocks
          blocks.empty? ? "The document is empty." : Tools.listing(@agent, blocks)
        end
      end

      class RewriteBlock < Tool
        description "Replaces the text of one block with `text`, as plain text. " \
                    "The block's formatting, such as bold or links, is lost."
        parameter :id, description: "The block's id, such as b3"
        parameter :text, description: "The block's new text"

        def execute(id:, text:)
          block = @agent.block(id) or return missing(id)
          @agent.edit { Lexical.replace_runs(block, text) }
          "Rewrote #{id}."
        end
      end

      class InsertParagraph < Tool
        description "Adds a paragraph holding `text`, after the block `after`, or at the end of the document."
        parameter :text, description: "The paragraph's text"
        parameter :after, description: "The id of the block it goes after. Leave it out to add it at the end.",
                          required: false

        def execute(text:, after: nil)
          block = nil
          @agent.edit do |doc|
            at = after ? @agent.ordinal(after)&.succ : -1
            block = Lexical.insert_paragraph(doc, at, text) if at
          end
          block ? "Added #{@agent.block_id(block)}." : missing(after)
        end
      end

      class DeleteBlock < Tool
        description "Deletes one block."
        parameter :id, description: "The block's id, such as b3"

        def execute(id:)
          deleted = false
          @agent.edit do |doc|
            ordinal = @agent.ordinal(id)
            deleted = Lexical.delete_block(doc, ordinal) if ordinal
          end
          deleted ? "Deleted #{id}." : missing(id)
        end
      end

      ALL = [ReadDocument, RewriteBlock, InsertParagraph, DeleteBlock].freeze
    end
  end
end
