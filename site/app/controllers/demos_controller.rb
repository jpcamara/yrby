# The live demos. Nothing here is cacheable: every page is bound to a room, and
# the room is where the state is.
class DemosController < ApplicationController
  before_action :no_store
  before_action :load_demo, only: %i[new_room show]

  def index
    @demos = Demos::ALL
  end

  # A bare /demos/:demo mints a room and redirects into it, so a visitor lands
  # in a room of their own without having to pick a name.
  def new_room
    redirect_to demo_room_path(@demo.slug, Demos.new_room)
  end

  def show
    @room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(@room)

    @document_key = Demos.document_key(@demo.slug, @room)
    return unless @demo.slug == "lexxy"

    # The Rich text demo is record-based (lexxy-realtime's shape): one Note per
    # room. The page does NOT create the Note — a GET is anonymous and
    # uncapped, and a crawler fetching room URLs would mint rows without bound.
    # It hands the client a signed, field-scoped room token instead; NoteChannel
    # verifies it and creates the Note on subscribe, within the room budget.
    @note_token = Note.room_token(@room, :body)
  end

  # The materialized column, as JSON. This is the part no other demo can
  # show: NoteChannel renders the document server-side (Y::Lexxy) into
  # note.body after every update, so this read-only endpoint always returns a
  # current HTML snapshot with no browser in the loop. The e2e polls it.
  def body
    room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(room)

    note = Note.find_by(room: room)
    render json: { body: note&.body }
  end

  private

  def load_demo
    @demo = Demos.find(params[:demo])
    head :not_found if @demo.nil?
  end

  def no_store
    response.headers["cache-control"] = "no-store"
  end
end
