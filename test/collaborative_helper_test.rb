# frozen_string_literal: true

require "test_helper"
require_relative "support/active_record"
require "y/collaborative"
require "global_id"
require "action_view"

GlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.app ||= "yrby-collaborative-test"
SignedGlobalID.verifier ||= GlobalID::Verifier.new("yrby-collaborative-test-secret")

# The view side: collaborative_document_tag renders the signed grant and the
# channel coordinates a client needs, and nothing else.
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

  def test_renders_the_grant_the_channel_accepts
    html = collaborative_document_tag(@page, :body)

    grant = html[/data-grant="([^"]+)"/, 1]

    assert_equal @page, Y::Collaborative.locate(grant, :body), "the rendered grant verifies to the record"
    assert_includes html, 'data-name="body"'
    assert_includes html, 'data-channel="Y::DocumentChannel"'
    assert_includes html, "data-collaborative-document"
  end

  def test_passes_options_and_content_through
    html = collaborative_document_tag(@page, :body, id: "editor", class: "doc") { "loading" }

    assert_includes html, 'id="editor"'
    assert_includes html, 'class="doc"'
    assert_includes html, ">loading</div>"
  end

  def test_extra_data_merges_without_clobbering_the_grant
    html = collaborative_document_tag(@page, :body, data: { controller: "editor" })

    assert_includes html, 'data-controller="editor"'
    assert_match(/data-grant="[^"]+"/, html)
  end
end
