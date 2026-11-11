# The agent board: a whiteboard where each person can bring an agent that
# draws (app/agents/board_agent.rb). It's a page of its own, like the shared
# Lexxy page, on the room's "board" document. Starting a room and inviting an
# agent are POSTs with no body that check the Origin, as in DemosController.
class BoardsController < ApplicationController
  skip_forgery_protection only: %i[start agent]
  before_action :no_store
  before_action :load_slug

  # The seat key for a person's agent on a board. It's apart from the Lexxy
  # page's, so each page takes its own agents.
  def self.seat(room) = "board:#{room}"

  # /board picks a new room id.
  def new = redirect_to(board_path(@slug))

  def show
    @room = Room.find_by(slug: @slug)
    return render :start, status: :not_found unless @room

    @document = @room.collaborative_document(:board)
    render layout: "board"
  end

  def start
    return head :forbidden unless request.origin == request.base_url
    unless Rooms.current.start(@slug)
      return render plain: "The demos have as many rooms as they can hold. Try again later.\n",
                    status: :service_unavailable
    end

    redirect_to board_path(@slug), status: :see_other
  end

  # Invites one person's agent onto the board. The person's id, name, and
  # color come in the query string.
  def agent
    return head :not_found unless Room.exists?(slug: @slug)
    return head :forbidden unless request.origin == request.base_url

    owner = agent_owner or return head(:unprocessable_content)
    case AgentSeats.current.take(self.class.seat(@slug), owner[:id])
    when :ok
      BoardAgentJob.perform_later(@slug, request.base_url, owner)
      render json: { status: "joining" }, status: :accepted
    when :here then render json: { status: "here" }
    else render json: { status: "busy" }, status: :service_unavailable
    end
  end

  private

  def load_slug
    @slug = params[:room]&.to_s || Demos.new_room
    head :not_found unless Demos.valid_room?(@slug)
  end

  def agent_owner
    id, name, color = params.values_at(:owner, :name, :color).map(&:to_s)
    return unless id.match?(/\A[A-Za-z0-9-]{8,64}\z/) && name.match?(/\A[\p{L} ]{1,24}\z/) && color.match?(/\A#\h{6}\z/)

    { id:, name:, color: }
  end

  def no_store
    response.headers["cache-control"] = "no-store"
  end
end
