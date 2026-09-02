# frozen_string_literal: true

module Y
  # The gem-shipped channel behind collaborative_document_tag — the whole wire
  # side of a record-backed collaborative document, the way Turbo::StreamsChannel
  # is the whole wire side of a turbo_stream_from subscription. Apps subscribe
  # to it by name ("Y::DocumentChannel") with the grant the tag rendered; there
  # is no channel to generate or write.
  #
  # The client never names a document. It presents the signed, attribute-scoped
  # grant minted where the page rendered (record.collaborative_sgid(name)), and
  # the document is whatever that grant verifies to. Authorization happened
  # when your controller decided to render the tag; the grant carries that
  # decision to the socket. A missing, tampered, expired, or wrong-attribute
  # grant — or one whose record no longer exists — is rejected.
  #
  # Storage is the concern's Y::Document default: state rebuilds from your
  # database on join, and every change is recorded there before it is
  # acknowledged or broadcast. Point storage elsewhere by writing your own
  # channel (see the yrby-rails README).
  # ::ActionCable, explicitly — inside module Y a bare ActionCable resolves
  # to the gem's own Y::ActionCable concern.
  class DocumentChannel < ::ActionCable::Channel::Base
    include Y::ActionCable

    def subscribed = sync_subscribed(document&.key)

    def receive(data) = sync_receive(data, document&.key)

    private

    def authorized?(_key) = record.present?

    # Re-derived per command: under AnyCable each RPC call builds a fresh
    # channel instance, and verifying the signature is cheap.
    def record
      @record ||= Y::Collaborative.locate(params[:grant], params[:name])
    end

    def document
      record && Y::Document.for(record, params[:name].to_s)
    end
  end
end
