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
  # Same DocumentChannel, same durable store.
  def rhino
    @document_id = params[:id]
    @note = Note.find_by(document_id: @document_id)
  end

  # Rhino is Tiptap under the hood, so Y::Tiptap is its renderer; the one
  # place its serialized HTML deliberately differs from stock is strike —
  # Rhino replaces Tiptap's Strike with its own "rhino-strike" mark and
  # emits <del>, not <s>. One mark rule teaches the renderer the custom mark.
  RHINO_RENDER_RULES = { marks: { "rhino-strike" => { tag: "del" } } }.freeze

  # The ActionText save, derived from the CRDT rather than the client: no
  # editor HTML crosses the wire. The durable store replays into a Y::Doc and
  # Y::Tiptap renders the Rhino page's fragment server-side, so what
  # lands in ActionText is what the authoritative document says — not what
  # the submitting browser claims it says.
  def rhino_save
    update = Store.current.replay(params[:id])
    if update.nil?
      return redirect_to document_rhino_path(params[:id]), alert: "Nothing recorded for this document yet."
    end

    ydoc = Y::Doc.new
    ydoc.apply_update(update)
    html = Y::Tiptap.new(ydoc, **RHINO_RENDER_RULES).to_html("rhino")
    if html.nil?
      return redirect_to document_rhino_path(params[:id]), alert: "No Rhino content in this document yet."
    end

    # create_or_find_by!: two browsers saving a fresh document concurrently
    # both reach here; the unique index turns the loser's INSERT into a find
    # instead of a RecordNotUnique raise. Content is then last-write-wins,
    # which is fine — both render the same authoritative store.
    note = Note.create_or_find_by!(document_id: params[:id])
    note.content = html
    note.save!
    redirect_to document_rhino_path(params[:id]), notice: "Saved to ActionText from the CRDT."
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
    Store.current.reset!(params[:id]) if params[:reset]
    Fault.set_delay(params[:id], params[:delay_ms].to_f / 1000) if params[:delay_ms]
    Fault.fail_next(params[:id]) if params[:fail_once]
    head :no_content
  end
end
