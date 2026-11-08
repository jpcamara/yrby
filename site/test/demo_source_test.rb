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

  # The lines between a file's "begin source excerpt" and "end source
  # excerpt" comments.
  def marked_region(path)
    Rails.root.join(path).read[%r{(?:#|//|<%#) begin source excerpt.*?\n(.*?)^\s*(?:#|//|<%#) end source excerpt}m, 1]
  end

  test "every shape demo page shows its view and script as they are on disk" do
    Demos::ALL.reject { |demo| demo.slug == "lexxy" }.each do |demo|
      get "/demos/#{demo.slug}/room1"

      assert_shows_files ["app/views/demos/_#{demo.slug}.html.erb", "frontend/src/#{demo.slug}.js"]
    end
  end

  test "the lexxy page shows the marked lines of its model, view, and script" do
    get "/demos/lexxy/room1"

    assert_response :success
    blocks = source_blocks

    assert_equal ["app/models/room.rb", "app/views/demos/_lexxy.html.erb", "frontend/src/lexxy.js"], blocks.keys

    model = marked_region("app/models/room.rb")

    assert_equal "class Room < ApplicationRecord\n#{model}end\n", blocks["app/models/room.rb"]
    assert_equal marked_region("app/views/demos/_lexxy.html.erb"), blocks["app/views/demos/_lexxy.html.erb"]
    assert_equal marked_region("frontend/src/lexxy.js"), blocks["frontend/src/lexxy.js"]
  end

  test "the lexxy page shows the recipe from the quick start and none of the site's plumbing" do
    get "/demos/lexxy/room1"
    blocks = source_blocks

    assert_equal <<~RUBY, blocks["app/models/room.rb"]
      class Room < ApplicationRecord
        # nodes: renders attachment nodes as nothing, because the site takes no uploads.
        has_collaborative_rich_text :body, nodes: SUPPRESSED_NODES
      end
    RUBY
    assert_equal <<~ERB, blocks["app/views/demos/_lexxy.html.erb"]
      <%= form_with model: @room do |form| %>
        <%= form.collaborative_rich_textarea :body %>
      <% end %>
    ERB
    assert_equal %(import "@37signals/lexxy"\nimport "lexxy-realtime"\n), blocks["frontend/src/lexxy.js"]

    shown = blocks.values.join

    ["shape_slugs", "has_many", "to_param", "SUPPRESSED_NODES = ", "stored-html", "Stored HTML",
     "lexxy.css", "room.js", "setConsumer", "setupRoomPage", "yrby:synced"].each do |plumbing|
      assert_not_includes shown, plumbing
    end
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
