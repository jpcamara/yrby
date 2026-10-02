class ExamplesController < ApplicationController
  before_action do
    response.headers["cache-control"] = "no-store"
    @document = ExampleDocument.find(1)
  end

  # This record is deliberately public. In an app, authorize editing here
  # before rendering collaborative_document_tag.
  def document; end

  def stored
    render json: { body: @document.collaborative_document(:body).y_doc.read_text("content") }
  end
end
