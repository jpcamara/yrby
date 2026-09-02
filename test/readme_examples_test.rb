# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/yjs_fixtures"
require_relative "support/active_record"
require "y/action_cable"
require_relative "../app/models/y/document"
require_relative "../app/models/y/document_update"
require_relative "../app/models/y/encrypted_document"
require_relative "../app/models/y/encrypted_document_update"

# Runs the ```ruby blocks from README.md against the real gem, so an
# example that drifts from the API fails the suite. Each block evaluates
# in its own anonymous module with a prelude supplying the names examples
# use without declaring (doc, key, a store, channel scaffolding).
class ReadmeExamplesTest < Minitest::Test
  README = File.expand_path("../README.md", __dir__)

  # Gemfile fragments: every non-blank line is a comment or a gem call.
  def gemfile_fragment?(block)
    block.lines.map(&:strip).reject(&:empty?).all? { |l| l.start_with?("#", "gem \"") }
  end

  FIXTURES = File.expand_path("../ext/yrby/crates/lexical-html/src/fixtures", __dir__)

  PRELUDE = <<~RUBY.freeze
    doc = Y::Doc.new
    doc.apply_update(File.binread(File.join(#{FIXTURES.inspect}, "lexxy_full.bin")))
    ydoc = doc
    key = "readme-example-\#{name}"
    Y::Document.append(key, YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    update = YjsFixtures::TwoDocsMerged::DOC2_UPDATE
    update_bytes = update
    sv = doc.encode_state_vector
    data = Y::Doc.new.sync_step1
    frame = Y.wrap_update(update)
    note = Struct.new(:content).new
    post_class = Class.new(ActiveRecord::Base) do
      self.table_name = "pages"
      def self.name = "Page" # record binding derives keys from the class name
    end
    post = post_class.create!(title: "readme")
    Y::Document.for(post, :body).append(YjsFixtures::TwoDocsMerged::DOC1_UPDATE)
    store = Class.new do
      def replay(_id) = YjsFixtures::TwoDocsMerged::DOC1_UPDATE
      def record!(_id, _update) = nil
      def load(_id) = nil
    end.new
    module ApplicationCable
      class Channel
        def self.identifier = nil
        # anycable-rails macro; an ordinary accessor on plain Action Cable.
        def self.state_attr_accessor(*names) = attr_accessor(*names)
        def params = {}
        def reject = nil
      end
    end
  RUBY

  def setup
    Y::DocumentUpdate.delete_all
    Y::Document.delete_all
  end

  def test_readme_ruby_examples
    executed = 0
    File.read(README).scan(/^```ruby\n(.*?)^```/m).map(&:first).each_with_index do |block, i|
      next if gemfile_fragment?(block)

      executed += 1
      container = Module.new
      container.module_eval(PRELUDE + block, "README.md:example_#{i + 1}")
    rescue Exception => e # rubocop:disable Lint/RescueException -- report which example broke
      flunk "README example #{i + 1} raised #{e.class}: #{e.message}\n#{block}"
    end

    assert_operator executed, :>=, 10, "extraction found too few runnable examples"
  end
end
