# frozen_string_literal: true

class DocumentsController < ApplicationController
  # The audit control endpoint is a test hook (POST without a form token).
  skip_forgery_protection only: :audit_control

  # The collaborative editor page.
  def show
    @document_id = params[:id]
  end

  # Server-side read of the live document — ProseMirror JSON extracted
  # natively from the CRDT, no JavaScript involved. Open in another tab
  # while editing to watch it change.
  def content
    awareness = YrbLite::Sync.registry[params[:id]]
    return render json: { error: "No such document" }, status: :not_found unless awareness

    render json: YrbLite::ProseMirrorExtractor.extract(awareness.encode_state_as_update)
  rescue RuntimeError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # The authoritative audit log for a document (AUDIT mode): every recorded
  # change, in order, as base64 CRDT update deltas. Replaying them rebuilds
  # the document exactly.
  def audit
    entries = AuditLog.entries(params[:id])
    render json: { count: entries.length, updates: entries }
  end

  # Test hook (AUDIT mode only): drive the audit store's behavior so the
  # end-to-end suite can prove the record-before-distribute guarantee.
  #   reset=1        clear this document's log + injected faults
  #   delay_ms=N     make the next writes take N ms (a slow durable store)
  #   fail_once=1    make the next write raise (store unavailable)
  def audit_control
    return head :forbidden unless ENV["AUDIT"].present?

    AuditLog.reset!(params[:id]) if params[:reset]
    AuditLog.set_delay(params[:id], params[:delay_ms].to_f / 1000) if params[:delay_ms]
    AuditLog.fail_next(params[:id]) if params[:fail_once]
    head :no_content
  end
end
