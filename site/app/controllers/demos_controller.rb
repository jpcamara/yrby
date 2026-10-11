# The live demos. None of these responses can be cached, because every page
# belongs to a room and the room's state changes.
class DemosController < ApplicationController
  before_action :no_store
  before_action :load_demo, only: %i[new_room show]

  def index
    @demos = Demos::ALL
  end

  # A bare /demos/:demo creates a room id and redirects to it, so each visitor
  # gets their own room without picking a name.
  def new_room
    redirect_to demo_room_path(@demo.slug, Demos.new_room)
  end

  def show
    @room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(@room)

    @document_key = Demos.document_key(@demo.slug, @room)

    if @demo.slug == "lexxy"
      # The Lexxy demo uses a record, like lexxy-realtime does, with one Note
      # per room. The page doesn't create the Note. A GET is anonymous and has
      # no limit, so a crawler fetching room URLs could create any number of
      # rows. The page renders a signed token for the room and field as the
      # <yrby-document> grant. NoteChannel verifies it and creates the Note on
      # subscribe, within the room limits.
      @note_grant = Note.room_token(@room, :body)
    else
      # The shape demos work the same way. This action signs a token for the
      # document, and DocumentChannel verifies it. The channel doesn't accept
      # a document key from the client, so a client without a token can't
      # subscribe.
      @room_token = Demos.room_token(@demo.slug, @room)
    end
  end

  # note.body as JSON. NoteChannel renders the document with Y::Lexxy after
  # every update and saves the HTML to note.body, so this read-only endpoint
  # returns current HTML without a browser involved. The e2e test polls it.
  def body
    room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(room)

    note = Note.find_by(room: room)
    render json: { body: note&.body }
  end

  # The shape demos' version of #body. It loads the stored Y::Document and
  # reads it in Ruby with read_text, read_xml, read_map, or read_array. Like
  # #body, it's read-only and anonymous. It never creates a document, so a
  # crawler fetching room URLs can't create rows.
  def stored
    demo = Demos.find(params[:demo])
    return head :not_found if demo.nil? || demo.read.nil?

    room = params[:room].to_s
    return head :not_found unless Demos.valid_room?(room)

    state = Y::Document.load_state(Demos.document_key(demo.slug, room))
    render json: { body: Demos.read_stored(demo.read, state) }
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
