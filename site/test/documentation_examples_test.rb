require "test_helper"

# Execute the actual published code blocks, so valid rendered markdown cannot
# hide a broken Ruby contract or loss of acknowledged CRDT dependencies.
class DocumentationExamplesTest < ActiveSupport::TestCase
  def ruby_blocks(page)
    Rails.root.join("docs", "#{page}.md").read.scan(/```ruby\n(.*?)```/m).flatten
  end

  test "the getting-started read works with empty built-in and custom storage" do
    @post = ExampleDocument.find_or_create_by!(id: 1)
    example = ruby_blocks("getting-started").find { |code| code.include?("collaborative_document(:body).doc") }

    assert_nil eval(example, binding) # rubocop:disable Security/Eval

    store = Object.new
    store.define_singleton_method(:load) { |_record, _name| Updates::HELLO }
    store.define_singleton_method(:write) { |_record, _name, _update| nil }
    original = ExampleDocument.collaborative_document_options
    begin
      ExampleDocument.has_collaborative_document :body, storage: store

      assert_equal "hello world", eval(example, binding) # rubocop:disable Security/Eval
    ensure
      ExampleDocument.collaborative_document_options = original
    end
  end

  %w[storage anycable].each do |page|
    test "#{page} scratchpad example preserves a gap until its dependency arrives" do
      code = ruby_blocks(page).find { |block| block.include?("class ScratchpadChannel") }
      namespace = Module.new
      namespace.module_eval(code)
      channel = namespace.const_get(:ScratchpadChannel).allocate
      # RPC state serialization is covered by AnyCable; give this hook probe a
      # state slot so it can execute the exact example's on_load/on_change.
      channel.singleton_class.attr_accessor :doc_state
      klass = channel.class
      [Updates::CHAIN[0], Updates::CHAIN[2]].each do |update|
        channel.instance_exec("scratch", update, &klass.on_change)
      end
      state = channel.instance_exec("scratch", &klass.on_load)
      doc = Y::Doc.new
      doc.apply_update(state)

      assert_predicate doc, :pending?
      doc.apply_update(Updates::CHAIN[1])

      assert_equal "ABC", doc.read_text("content")
      assert_not_predicate doc, :pending?
    end
  end
end
