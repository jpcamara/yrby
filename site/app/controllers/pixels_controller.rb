# The pixel canvas's two Ruby renders. Read-only and anonymous like
# DemosController#stored: each loads the room's document if it exists and
# never creates one, so crawling room URLs can't mint rows.
class PixelsController < ApplicationController
  before_action :no_store
  before_action :load_key

  # The current canvas as a 512 px PNG, drawn in Ruby from read_map. A room
  # with no document yet renders blank, so the URL always answers as an image.
  def png
    cells = PixelCanvas.cells(Y::Document.load_state(@key))
    send_data PixelCanvas.png(cells), type: "image/png", disposition: "inline"
  end

  # The canvas replayed from the stored rows, as the PNG frames the page
  # scrubs through.
  def timelapse
    updates, frames = PixelCanvas.replay(Y::Document.find_by(key: @key))
    render json: {
      updates: updates,
      frames: frames.map { |frame| { after: frame.after, png: data_uri(frame.png) } }
    }
  end

  private

  def data_uri(png) = "data:image/png;base64,#{Base64.strict_encode64(png)}"

  def load_key
    room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(room)

    @key = Demos.document_key("pixels", room)
  end

  def no_store
    response.headers["cache-control"] = "no-store"
  end
end
