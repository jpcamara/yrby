# The live demos. None of these responses can be cached, because every page
# belongs to a room and the room's state changes.
class DemosController < ApplicationController
  # Starting a room is a POST, from a demo link or from the page of a room
  # nobody has started. The site has no sessions
  # to hold a CSRF token, so #start checks that the request's Origin is this
  # site instead.
  skip_forgery_protection only: :start
  before_action :no_store
  before_action :load_demo, only: %i[new_room show start stored]
  before_action :load_slug, only: %i[show start body stored]

  def index
    @demos = Demos::ALL
  end

  # A bare /demos/:demo picks a room id and redirects to it, so each visitor
  # gets their own room without picking a name. The demo links POST to #start
  # instead, which also creates the room.
  def new_room
    redirect_to demo_room_path(@demo.slug, Demos.new_room)
  end

  # A room's page, with the demo's document. Every page renders
  # collaborative_document_tag, so the client never names a document. A GET never creates the
  # room (see #start), so a room nobody has started shows a button that
  # starts it.
  def show
    @room = Room.find_by(slug: @slug)
    return render :start, status: :not_found unless @room

    @document = @room.collaborative_document(Demos.field(@demo))
  end

  # Starts a room: creates its row, within the room cap, and redirects to it.
  # A POST to /demos/:demo/start has no room, so it starts a new one.
  # The pages never create a room, because a GET is anonymous and a crawler
  # fetching room URLs could create any number of rows. This is a POST with
  # no body, and Rack::Attack throttles it per IP.
  def start
    return head :forbidden unless request.origin == request.base_url
    unless Rooms.current.start(@slug)
      return render plain: "The demos have as many rooms as they can hold. Try again later.\n",
                    status: :service_unavailable
    end

    redirect_to demo_room_path(@demo.slug, @slug), status: :see_other
  end

  # The HTML stored in room.body, an Action Text field, as JSON. LexxyChannel
  # renders the Lexxy document with Y::Lexxy after every update and saves the
  # HTML to room.body, so this read-only endpoint returns current HTML without
  # a browser involved. It's the stored string, not Action Text's rendered
  # layout. The e2e test polls it.
  def body
    rich_text = Room.find_by(slug: @slug)&.body
    render json: { body: rich_text&.body&.to_html }
  end

  # The shape demos' version of #body. It loads the room's stored document
  # and reads it in Ruby with read_text, read_xml, read_map, or read_array.
  # Like #body, it's read-only and anonymous.
  def stored
    return head :not_found if @demo.read.nil?

    state = Room.find_by(slug: @slug)&.collaborative_document(@demo.slug)&.load_state
    render json: { body: Demos.read_stored(@demo.read, state) }
  end

  private

  def load_demo
    @demo = Demos.find(params[:demo])
    head :not_found if @demo.nil?
  end

  def load_slug
    @slug = params[:room]&.to_s || Demos.new_room
    head :not_found unless Demos.valid_room?(@slug)
  end

  def no_store
    response.headers["cache-control"] = "no-store"
  end
end
