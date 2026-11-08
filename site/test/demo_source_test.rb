require "test_helper"

# Every demo page, and the record-backed example, shows the files it runs. The
# panels read the files from disk, so the text on the page has to match them.
class DemoSourceTest < ActionDispatch::IntegrationTest
  setup do
    Rack::Attack.cache.store.clear
    Room.create!(slug: "room1")
    ExampleDocument.find_or_create_by!(id: 1)
  end

  def source_blocks
    Nokogiri::HTML5(response.body).css(".source-files > div").to_h do |sheet|
      [sheet.at_css("span").text, sheet.at_css("pre").text]
    end
  end

  def assert_shows_files(paths)
    assert_response :success
    blocks = source_blocks

    assert_equal paths, blocks.keys
    paths.each do |path|
      assert_equal Rails.root.join(path).read, blocks[path], "#{path} on the page doesn't match the file"
    end
  end

  test "every demo page shows its view and script as they are on disk" do
    Demos::ALL.each do |demo|
      get "/demos/#{demo.slug}/room1"

      files = ["app/views/demos/_#{demo.slug}.html.erb", "frontend/src/#{demo.slug}.js"]
      files.unshift("app/models/room.rb") if demo.slug == "lexxy"

      assert_shows_files files
    end
  end

  test "the lexxy page shows the model and form from the quick start" do
    get "/demos/lexxy/room1"
    blocks = source_blocks

    assert_includes blocks["app/models/room.rb"], "has_collaborative_rich_text :body"
    form = "<%= form_with model: @room do |form| %>\n  <%= form.collaborative_rich_textarea :body %>\n<% end %>"

    assert_includes blocks["app/views/demos/_lexxy.html.erb"], form
    assert_includes blocks["frontend/src/lexxy.js"], %(import { setConsumer } from "lexxy-realtime")
  end

  test "the record-backed example shows its view and script as they are on disk" do
    get "/examples/document"

    assert_shows_files ["app/views/examples/document.html.erb", "frontend/src/document.js"]
  end

  test "the source is highlighted and escaped" do
    get "/demos/tiptap/room1"

    pre = Nokogiri::HTML5(response.body).css(".source-files pre").first

    assert_predicate pre.css("span[style]"), :any?, "the view source has no highlighting"
    assert_includes pre.text, "<%= collaborative_document_tag"
    assert_empty pre.css("yrby-document")
  end
end
