# frozen_string_literal: true

# Reads and writes a synced document from Ruby.
class DocumentsController < RageController::API
  def show
    render plain: load_doc.read_text("body")
  end

  # Records an edit, then sends it to the clients through anycable-go.
  def append
    doc = load_doc
    update = doc.edit { doc.get_text("body").push(params[:text].to_s) }
    Y::Document.append(params[:id], update)
    Y::AnyCable.broadcast(params[:id], update)
    head :no_content
  end

  # A JWT for anycable-go to verify, carrying the connection's identifiers.
  def token
    render plain: AnyCable::JWT.encode({ "user" => params[:user] })
  end

  private

  def load_doc
    Y::Doc.new.tap do |doc|
      state = Y::Document.load_state(params[:id])
      doc.apply_update(state) if state
    end
  end
end
