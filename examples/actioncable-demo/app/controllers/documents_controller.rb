# frozen_string_literal: true

class DocumentsController < ApplicationController
  # The audit control endpoint is a test hook (POST without a form token).
  skip_forgery_protection only: :audit_control

  # The collaborative editor page (Tiptap).
  def show
    @document_id = params[:id]
  end

  # The same document, edited through a Lexxy (Lexical) editor via
  # lexxy-realtime. Same DocumentChannel, same durable store — just a different
  # front end, to show the yrby protocol is editor-agnostic.
  def lexxy
    @document_id = params[:id]
  end

  # A third front end: Rhino Editor (Tiptap 3, ActionText-compatible), bound
  # through Tiptap's own Collaboration extensions — the real-app recipe.
  # Same DocumentChannel, same durable store. The note is freshened on read
  # (see NoteMaterializer): rendered server-side from the authoritative
  # store whenever the store has changes it hasn't seen — no editor HTML
  # ever crosses the wire.
  def rhino
    @document_id = params[:id]
    @note = NoteMaterializer.fresh(@document_id)
  end

  # "Opaque state" demos. Each renders a different kind of collaborative app over
  # the SAME DocumentChannel, to show yrby syncs any Yjs shape (the views use
  # a per-demo suffix on the document id so the shapes don't collide).
  def codemirror = (@document_id = params[:id]) # Y.Text  (code, with cursors)
  def whiteboard = (@document_id = params[:id]) # Y.Map   (draggable shapes)
  def kanban     = (@document_id = params[:id]) # Y.Array (cards)
  def forms      = (@document_id = params[:id]) # Y.Map   (form fields)

  # Server-side read of the authoritative document: the raw CRDT state,
  # base64-encoded. Replays the durable store into a fresh Y.Doc state.
  def content
    update = Store.current.replay(params[:id])
    return render json: { error: "No such document" }, status: :not_found unless update

    render json: { state: Base64.strict_encode64(update) }
  end

  # The audit log for a document (AUDIT mode): every recorded change, in order,
  # as base64 CRDT update deltas. Replaying them rebuilds the document.
  def audit
    entries = Store.current.entries(params[:id])
    render json: { count: entries.length, updates: entries }
  end

  # Test hook: drive the durable store's behavior so the end-to-end suite can
  # exercise record-before-distribute.
  #   reset=1        clear this document's log + injected faults
  #   delay_ms=N     make the next writes take N ms (a slow durable store)
  #   fail_once=1    make the next write raise (store unavailable)
  def audit_control
    if params[:reset]
      Store.current.reset!(params[:id])
      # Clearing a document's history invalidates its derived view — and the
      # store version restarts, so a surviving note's stamp would read as
      # "fresh" against the smaller version forever.
      Note.where(document_id: params[:id]).destroy_all
    end
    Fault.set_delay(params[:id], params[:delay_ms].to_f / 1000) if params[:delay_ms]
    Fault.fail_next(params[:id]) if params[:fail_once]
    head :no_content
  end
end
