# The live demos. None of these responses can be cached, because every page
# belongs to a room and the room's state changes.
class DemosController < ApplicationController
  # Starting a room is a POST, from a demo link or from the page of a room
  # nobody has started, and inviting an agent is a POST from the shared page.
  # The site has no sessions to hold a CSRF token, so #start and #agent check
  # that the request's Origin is this site instead.
  skip_forgery_protection only: %i[start agent]
  before_action :no_store
  before_action :load_demo, only: %i[new_room show start stored]
  before_action :load_slug, only: %i[show start body stored space agent]

  def index
    @demos = Demos::ALL
  end

  # A bare /demos/:demo picks a room id and redirects to it, so each visitor
  # gets their own room without picking a name. The demo links POST to #start
  # instead, which also creates the room.
  def new_room
    redirect_to demo_room_path(@demo.slug, Demos.new_room)
  end

  # A room's page, with the demo's document. The page renders
  # collaborative_document_tag (Lexxy) or the document's grant (the shape
  # demos), so the client never names a document. A GET never creates the
  # room (see #start), so a room nobody has started shows a button that
  # starts it.
  def show
    @room = Room.find_by(slug: @slug)
    return render :start, status: :not_found unless @room

    @document = @room.collaborative_document(Demos.field(@demo))
  end

  # The room's Lexxy document as a shared page, where each person can invite
  # their own agent and ask it to change a selection.
  def space
    @demo = Demos.find("lexxy")
    @space = true
    @room = Room.find_by(slug: @slug)
    return render :start, status: :not_found unless @room

    @document = @room.collaborative_document(:body)
    render layout: "space"
  end

  # /space picks a new room id for the shared page.
  def new_space = redirect_to(demo_space_path(Demos.new_room))

  # Starts a room: creates its row, within the room cap, and redirects to it.
  # A POST to /demos/:demo/start has no room, so it starts a new one.
  # The pages never create a room, because a GET is anonymous and a crawler
  # fetching room URLs could create any number of rows. This is a POST with
  # no body, and Rack::Attack throttles it per IP. ?space=1 goes on to the
  # shared page.
  def start
    return head :forbidden unless request.origin == request.base_url
    unless Rooms.current.start(@slug)
      return render plain: "The demos have as many rooms as they can hold. Try again later.\n",
                    status: :service_unavailable
    end

    redirect_to params[:space] ? demo_space_path(@slug) : demo_room_path(@demo.slug, @slug), status: :see_other
  end

  # room.body as JSON. LexxyChannel renders the Lexxy document with Y::Lexxy
  # after every update and saves the HTML to room.body, so this read-only
  # endpoint returns current HTML without a browser involved. The e2e test
  # polls it.
  def body
    render json: { body: Room.find_by(slug: @slug)&.body }
  end

  # Invites one person's agent into a room's Lexxy document. The agent runs as
  # a PageAgentJob in a job process and leaves when the room empties. The
  # person's id, name, and color come in the query string, because the method
  # gate only lets this POST through with no body.
  def agent
    return head :not_found unless Room.exists?(slug: @slug)
    return head :forbidden unless request.origin == request.base_url

    owner = agent_owner or return head(:unprocessable_content)
    case AgentSeats.current.take(@slug, owner[:id])
    when :ok
      PageAgentJob.perform_later(@slug, request.base_url, owner)
      render json: { status: "joining" }, status: :accepted
    when :here then render json: { status: "here" }
    else render json: { status: "busy" }, status: :service_unavailable
    end
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

  # The inviting person, as the page knows them: a random id, one of the
  # demo's names, and a color.
  def agent_owner
    id, name, color = params.values_at(:owner, :name, :color).map(&:to_s)
    return unless id.match?(/\A[A-Za-z0-9-]{8,64}\z/) && name.match?(/\A[\p{L} ]{1,24}\z/) && color.match?(/\A#\h{6}\z/)

    { id:, name:, color: }
  end

  def no_store
    response.headers["cache-control"] = "no-store"
  end
end
