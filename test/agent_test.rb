# frozen_string_literal: true

require "test_helper"
require "y/agent"
require_relative "support/document_room"

# Y::Agent: a collaborator whose changed asks a model, with tools that edit
# the document.
class AgentTest < Minitest::Test
  include DocumentRoom

  RubyLLM.configure { |config| config.openai_api_key ||= "test-key" } # chats are built, never sent

  class Proofreader < Y::Agent
    model "gpt-5.6-luna", provider: :openai, assume_model_exists: true
    instructions "Fix typos in the blocks people change. Change nothing else."
  end

  # Stands in for the model: it reads the document, then rewrites the first
  # block it was asked about in capitals, through the tools it was given.
  class ScriptedChat
    attr_reader :asked

    def initialize(tools)
      @tools = tools.to_h { |tool| [tool.name, tool] }
      @asked = []
    end

    def ask(message)
      @asked << message
      @tools.fetch("read_document").call
      id, text = message.match(/^(b\d+) \(paragraph\): (.*)$/).captures
      @tools.fetch("rewrite_block").call(id:, text: text.upcase)
    end
  end

  class Shouter < Y::Agent
    attr_reader :chats

    def initialize(...)
      super
      @chats = []
      self.presence = { "user" => { "name" => "Shouter" } }
    end

    def chat = ScriptedChat.new(document_tools).tap { |chat| @chats << chat }
  end

  def test_a_chat_has_the_model_the_instructions_and_the_document_tools
    chat = Proofreader.new(@document, url: "ws://unused", lock: nil).chat

    assert_equal "gpt-5.6-luna", chat.model.id
    assert_equal ["Fix typos in the blocks people change. Change nothing else."],
                 chat.messages.select { |m| m.role == :system }.map(&:content)
    assert_equal %i[read_document rewrite_block insert_paragraph delete_block], chat.tools.keys
  end

  # Each ask starts over, so a long stay never sends the model a growing
  # history, and reads the document as it is now.
  def test_each_chat_is_fresh
    agent = Proofreader.new(@document, url: "ws://unused", lock: nil)

    refute_same agent.chat, agent.chat
  end

  def test_a_subclass_keeps_its_parents_settings_and_a_sibling_doesnt_see_them
    strict = Class.new(Proofreader) { instructions "Fix only spelling." }
    other = Class.new(Y::Agent) { model "claude-haiku-5-5", provider: :anthropic, assume_model_exists: true }

    assert_equal "gpt-5.6-luna", strict.model[:model]
    assert_equal "claude-haiku-5-5", other.model[:model]
    assert_equal "gpt-5.6-luna", Proofreader.model[:model]
    refute_equal strict.llm, Proofreader.llm
  end

  def test_changed_with_no_blocks_asks_nothing
    agent = Shouter.new(@document, url: "ws://unused", lock: nil)
    agent.changed([])

    assert_empty agent.chats
  end

  # A person types; once it settles, the agent's model rewrites the block
  # through the tools, and the person sees the rewrite arrive.
  def test_the_model_edits_what_a_person_wrote_through_the_tools
    ada = person
    names = roster(ada)
    run = collaborator(Shouter)
    wait_until { names.call.include?("Shouter") }

    ada.edit { |doc| Y::Lexxy.append_paragraph(doc, "please ship it") }

    assert(wait_until { doc_of(ada).read_xml("root").to_s.include?("PLEASE SHIP IT") })
    run.kill
  end
end
