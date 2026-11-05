# frozen_string_literal: true

require "ruby_llm"
require "y/collaborator"
require "yrby/agent/version"
require "y/agent/tools"

module Y
  # A collaborator with a model. It joins a document the way Y::Collaborator
  # does, and when people's typing settles it hands the blocks they changed to
  # a model through RubyLLM, with tools that read and edit the document:
  #
  #   class Proofreader < Y::Agent
  #     model "gpt-5.6-luna"
  #     instructions "Fix typos in the blocks people change. Change nothing else."
  #   end
  #
  #   class ProofreadJob < ApplicationJob
  #     def perform(post) = Proofreader.run(post.collaborative_document(:body), url: "wss://example.com/cable")
  #   end
  #
  # `model`, `instructions`, `tools`, `thinking`, and `temperature` are
  # RubyLLM::Agent's, and `llm` is the RubyLLM::Agent itself, for any other
  # setting. Each ask is a fresh chat: the tools read the document as it is
  # now, so the model needs no history, and a stay of hours never grows one.
  class Agent < Collaborator
    class << self
      # The RubyLLM::Agent this agent's chats come from. A subclass starts
      # with a copy of its parent's.
      def llm
        @llm ||= Class.new(superclass.respond_to?(:llm) ? superclass.llm : RubyLLM::Agent)
      end

      %i[model instructions tools thinking temperature].each do |setting|
        define_method(setting) { |*args, **options, &block| llm.public_send(setting, *args, **options, &block) }
      end
    end

    def initialize(document, **)
      super
      @anchors = {} # block id => anchor
      @ids = {}     # anchor => block id
    end

    # Asks the model `message` in a fresh chat with the document tools, and
    # returns the reply, a RubyLLM::Message. A block gets each chunk as it
    # streams in. The model's edits go through `edit`, so they reach people
    # as it makes them.
    def ask(message, &) = chat.ask(message, &)

    # Asks the model about the blocks people changed. Override it to ask
    # something else, or to call `ask` only sometimes.
    def changed(blocks)
      ask("People changed these blocks:\n\n#{Tools.listing(self, blocks)}") if blocks.any?
    end

    # The tools the model gets with each ask: Tools::ALL, which read the
    # document and edit its blocks. Override it to give the model fewer,
    # such as [Tools::ReadDocument] for an agent that only answers.
    def document_tools = Tools::ALL.map { |tool| tool.new(self) }

    # Live handles to the document's top-level blocks, in order.
    def document_blocks
      root = doc.get_xml_text(ROOT)
      (0...root.size).map { |ordinal| root.xml_text(ordinal) }
    end

    # A short id for `block`, such as "b3", that the model can name it by.
    # The id stays on its block for the whole stay, wherever people move it.
    def block_id(block)
      anchor = block.anchor
      @ids[anchor] ||= "b#{@ids.size + 1}".tap { |id| @anchors[id] = anchor }
    end

    # The live handle to the block `id` names, or nil once it's deleted.
    def block(id) = (anchor = @anchors[id]) && doc.find(anchor)

    # Where the block `id` names is now, or nil once it's deleted.
    def ordinal(id) = (anchor = @anchors[id]) && doc.block_at(anchor)

    # A fresh RubyLLM chat with the model, the instructions, and the
    # document tools. `ask` asks one; take one to set more on it first.
    def chat = self.class.llm.chat.with_tools(*document_tools)
  end
end
