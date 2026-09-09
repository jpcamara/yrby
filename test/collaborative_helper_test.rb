# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"
require "action_view"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# The view side: collaborative_document_tag renders the signed grant, channel
# name, and attribute name a client needs.
class CollaborativeHelperTest < Minitest::Test
  include ActionView::Helpers::TagHelper
  include Y::Collaborative::Helper

  class Page < ActiveRecord::Base
    self.table_name = "pages"
    include GlobalID::Identification
    include Y::Collaborative
  end

  def setup
    @page = Page.create!(title: "tagged")
  end

  def teardown
    Page.delete_all
  end

  def test_renders_the_element_with_the_grant_the_channel_accepts
    html = collaborative_document_tag(@page, :body)

    grant = html[/ grant="([^"]+)"/, 1]

    assert_match(/\A<yrby-document /, html)
    assert_equal @page, Y::Collaborative.locate(grant, :body), "the rendered grant verifies to the record"
    assert_includes html, 'name="body"'
  end

  # Pointing the tag at a subclass of the shipped channel is one attribute.
  def test_channel_option_names_the_channel_the_element_subscribes_to
    html = collaborative_document_tag(@page, :body, channel: "PostDocumentChannel")

    assert_includes html, 'channel="PostDocumentChannel"'
  end

  def test_passes_options_and_content_through
    html = collaborative_document_tag(@page, :body, id: "editor", class: "doc") { "loading" }

    assert_includes html, 'id="editor"'
    assert_includes html, 'class="doc"'
    assert_includes html, ">loading</yrby-document>"
  end

  def test_options_cannot_clobber_the_grant
    html = collaborative_document_tag(@page, :body, data: { controller: "editor" })

    assert_includes html, 'data-controller="editor"'
    grant = html[/ grant="([^"]+)"/, 1]

    assert_equal @page, Y::Collaborative.locate(grant, :body)
  end
end
