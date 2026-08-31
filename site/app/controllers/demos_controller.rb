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
