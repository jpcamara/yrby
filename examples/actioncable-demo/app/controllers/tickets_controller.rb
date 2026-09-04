# frozen_string_literal: true

# The yrby-forms demo: a plain Rails form whose fields collaborate.
class TicketsController < ApplicationController
  # The form page. Tickets are created on first visit so the e2e can use a
  # fresh id per run (demo only; a real app has its own creation flow).
  def show
    @ticket = Ticket.find_or_create_by!(id: params[:id])
  end

  # The materialized columns, for asserting that what the channel wrote
  # back matches what the clients converged on.
  def state
    ticket = Ticket.find(params[:id])
    render json: ticket.as_json(only: %i[status priority urgent due_on summary description])
  end
end
