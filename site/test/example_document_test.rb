require "test_helper"

class ExampleDocumentTest < ActionDispatch::IntegrationTest
  setup { @document = ExampleDocument.find_or_create_by!(id: 1) }

  test "seeding provisions the example once on a fresh database" do
    @document.destroy!
    load Rails.root.join("db/seeds.rb")

    assert_equal 1, ExampleDocument.find(1).id
    assert_no_difference "ExampleDocument.count" do
      load Rails.root.join("db/seeds.rb")
    end
  end

  test "the page renders a scoped grant without creating records or document rows" do
    assert_no_difference ["ExampleDocument.count", "Y::Document.count"] do
      get "/examples/document"
    end

    assert_response :success
    assert_equal "no-store", response.headers["cache-control"]
    element = Nokogiri::HTML5(response.body).at_css("yrby-document")

    assert_equal "body", element["name"]
    assert_equal @document, Y::Collaborative.locate(element["grant"], :body)
    assert_nil Y::Collaborative.locate(element["grant"], :secret)
  end

  test "Ruby read-back handles a new document and persisted edits" do
    get "/examples/document/stored"

    assert_response :success
    assert_nil response.parsed_body["body"]

    @document.collaborative_document(:body).append(Updates::HELLO)
    get "/examples/document/stored"

    assert_equal "hello world", response.parsed_body["body"]
  end
end
