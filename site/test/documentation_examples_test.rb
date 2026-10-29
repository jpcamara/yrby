require "test_helper"

# Runs the Ruby code blocks from the published docs. Markdown can render fine
# while the Ruby in it is broken, or while it drops updates that are still
# waiting on a dependency. These tests catch both.
class DocumentationExamplesTest < ActiveSupport::TestCase
  def ruby_blocks(page)
    Rails.root.join("docs", "#{page}.md").read.scan(/```ruby\n(.*?)```/m).flatten
  end

  test "the getting-started read works on an empty document and a written one" do
    @post = ExampleDocument.find_or_create_by!(id: 1)
    example = ruby_blocks("getting-started").find { |code| code.include?("collaborative_document(:body).y_doc") }

    assert_nil eval(example, binding) # rubocop:disable Security/Eval

    @post.collaborative_document(:body).append(Updates::HELLO)

    assert_equal "hello world", eval(example, binding) # rubocop:disable Security/Eval
  end

  %w[storage anycable].each do |page|
    test "#{page} scratchpad example preserves a gap until its dependency arrives" do
      code = ruby_blocks(page).find { |block| block.include?("class ScratchpadChannel") }
      namespace = Module.new
      namespace.module_eval(code)
      channel = namespace.const_get(:ScratchpadChannel).allocate
      # AnyCable's own tests cover RPC state serialization. Here the channel
      # just needs a doc_state accessor so the example's on_load and on_change
      # can run as written.
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
